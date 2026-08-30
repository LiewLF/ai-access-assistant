import Foundation

struct V011OptionalProviderProbeExpectation: Sendable {
    let providerID: String
    let contractID: String
    let profileID: String
    let profileHash: String
}

struct V011OptionalProviderProbePrepared: @unchecked Sendable {
    let kind: ProviderCapabilityProbeKind
    let userConsented: Bool
    let providerID: String
    let contractID: String
    let profile: CodexRelayProfile
    let secret: String
    let profileHash: String

    var expectation: V011OptionalProviderProbeExpectation {
        V011OptionalProviderProbeExpectation(
            providerID: providerID,
            contractID: contractID,
            profileID: profile.id,
            profileHash: profileHash
        )
    }
}

struct V011OptionalProviderProbeActionResult: @unchecked Sendable {
    let allReceipts: [ProviderCapabilityProbeReceipt]
    let differences: [String]
}

/// Two-phase boundary for optional authenticated provider probes.
/// Prepare remains synchronous; execute owns real probe, state CAS, receipt
/// issuance, authenticated append, and reload.
struct V011OptionalProviderProbeActionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func prepare(
        kind: ProviderCapabilityProbeKind,
        userConsented: Bool,
        currentProviderID: String?,
        currentContractID: String?,
        managedState: V011ManagedState
    ) throws -> V011OptionalProviderProbePrepared {
        guard [
            ProviderCapabilityProbeKind.serviceTier,
            .webSearchResponses,
            .imageInput,
        ].contains(kind),
        let probePlan = ProviderCapabilityProbePlan.optional
            .first(where: { $0.kind == kind }) else {
            throw V011ProviderCapabilityProbeRunError.unsupportedProbe
        }
        guard !probePlan.requiresExplicitConsent || userConsented else {
            throw ProviderCapabilityProbeReceiptError.consentRequired
        }
        guard let providerID = currentProviderID,
              let profile = managedState.relayProfiles.first(where: {
                  $0.v011ProviderID == providerID
              }) else {
            throw V011ProviderCapabilityProbeRunError
                .currentRelayRequired
        }
        guard let contractID = currentContractID else {
            throw V011ProviderCapabilityProbeRunError
                .currentContractRequired
        }
        let capability = profile.effectiveCapabilityProfile
        try V011OptionalProviderProbeService
            .validateOptionalProbeConfiguration(
                kind,
                capability: capability
            )
        let secret: String
        do {
            guard let storedSecret = try dependencies.credentialStore
                    .secret(reference: profile.v011CredentialReference),
                  !storedSecret.isEmpty else {
                throw V011ProviderCapabilityProbeRunError
                    .credentialMissing
            }
            secret = storedSecret
        } catch {
            throw V011ProviderCapabilityProbeRunError.credentialMissing
        }
        return V011OptionalProviderProbePrepared(
            kind: kind,
            userConsented: userConsented,
            providerID: providerID,
            contractID: contractID,
            profile: profile,
            secret: secret,
            profileHash: try ProviderCapabilityProfileIdentity
                .sha256(capability)
        )
    }

    func execute(
        _ prepared: V011OptionalProviderProbePrepared,
        validateCurrentState: @escaping @MainActor @Sendable
            (V011OptionalProviderProbeExpectation) throws -> Void
    ) async throws -> V011OptionalProviderProbeActionResult {
        let observations = try await V011OptionalProviderProbeService
            .performOptionalProviderCapabilityProbe(
                prepared.kind,
                profile: prepared.profile,
                apiKey: prepared.secret,
                userConsented: prepared.userConsented
            )
        try await validateCurrentState(prepared.expectation)
        let transactionID = "optional-\(UUID().uuidString)"
        let observedAt = dependencies.now()
        let receipts = try observations.map { observation in
            try ProviderCapabilityProbeReceiptFactory.issue(
                kind: observation.kind,
                status: observation.status,
                providerID: prepared.providerID,
                modelID: prepared.profile.defaultModel,
                codexContractID: prepared.contractID,
                transactionID: transactionID,
                observedAt: observedAt,
                stage: observation.stage,
                evidenceLevel: observation.evidenceLevel,
                responseStructureSHA256:
                    observation.responseStructureSHA256,
                evidenceComponents: observation.evidenceComponents,
                requestCount: observation.requestCount,
                userConsented: prepared.userConsented,
                containsSensitiveEvidence: false,
                profileID: prepared.profile.id,
                capabilityProfileSHA256: prepared.profileHash
            )
        }
        return V011OptionalProviderProbeActionResult(
            allReceipts: try evidenceService
                .appendAndReload(receipts),
            differences: receipts.filter {
                $0.status != .verified
            }.map {
                V011OptionalProviderProbeService
                    .optionalProbeName($0.kind)
            }
        )
    }

    private var evidenceService:
        V011ProviderCapabilityEvidenceService {
        V011ProviderCapabilityEvidenceService(
            controlRoot: dependencies.controlRoot,
            keyProvider: dependencies.keyProvider
        )
    }
}
