import Foundation

enum V011ProviderCapabilityEvidenceError: LocalizedError {
    case currentProfileOrContractUnavailable

    var errorDescription: String? {
        switch self {
        case .currentProfileOrContractUnavailable:
            return "当前轨档案或版本合同不完整"
        }
    }
}

/// Owns authenticated capability-receipt persistence and core receipt
/// construction. Probe execution remains in V011OptionalProviderProbeService.
struct V011ProviderCapabilityEvidenceService {
    private let receiptStore: ProviderCapabilityProbeReceiptStore

    init(
        controlRoot: URL,
        keyProvider: @escaping @Sendable () throws -> Data
    ) {
        receiptStore = ProviderCapabilityProbeReceiptStore(
            fileURL: controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent(
                    "provider-capability-probes.json"
                ),
            keyProvider: keyProvider
        )
    }

    func load() throws -> [ProviderCapabilityProbeReceipt] {
        try receiptStore.load()
    }

    func appendAndReload(
        _ receipts: [ProviderCapabilityProbeReceipt]
    ) throws -> [ProviderCapabilityProbeReceipt] {
        try receiptStore.append(receipts)
        return try receiptStore.load()
    }

    func persistCoreReceipts(
        for result: V011CurrentConnectionVerification,
        managedState: V011ManagedState
    ) throws -> [ProviderCapabilityProbeReceipt] {
        guard case let .verified(schemaID) =
                result.state.versionSupport,
              let profile = managedState.relayProfiles.first(where: {
                  $0.id == result.savedProfileID
                      || $0.v011ProviderID == result.providerID
              }),
              let profileHash = try?
                ProviderCapabilityProfileIdentity.sha256(
                    profile.effectiveCapabilityProfile
                ) else {
            throw V011ProviderCapabilityEvidenceError
                .currentProfileOrContractUnavailable
        }
        let transactionID = "connection-\(result.configHash)"
        let routeHash = ProviderCapabilityProbeReceiptFactory.sha256(
            Data(result.routeIdentity.utf8)
        )
        let responseStructureHash =
            ProviderCapabilityProbeReceiptFactory.sha256(
                Data("responses-output-present".utf8)
            )
        let receipts = try [
            coreReceipt(
                kind: .configurationSyntax,
                evidenceLevel: .fixedContractAndLive,
                responseStructureSHA256: nil,
                requestCount: 0,
                evidenceComponents: [
                    "config-sha256=\(result.configHash)",
                    "wire-api=responses",
                ],
                result: result,
                schemaID: schemaID,
                profile: profile,
                profileHash: profileHash,
                transactionID: transactionID
            ),
            coreReceipt(
                kind: .authentication,
                evidenceLevel: .response,
                responseStructureSHA256: nil,
                requestCount: 0,
                evidenceComponents: [
                    "authorization=accepted",
                    "route-sha256=\(routeHash)",
                ],
                result: result,
                schemaID: schemaID,
                profile: profile,
                profileHash: profileHash,
                transactionID: transactionID
            ),
            coreReceipt(
                kind: .responsesText,
                evidenceLevel: .response,
                responseStructureSHA256: responseStructureHash,
                requestCount: 1,
                evidenceComponents: [
                    "responses-output=present",
                    "route-sha256=\(routeHash)",
                ],
                result: result,
                schemaID: schemaID,
                profile: profile,
                profileHash: profileHash,
                transactionID: transactionID
            ),
            coreReceipt(
                kind: .configurationCAS,
                evidenceLevel: .fixedContractAndLive,
                responseStructureSHA256: nil,
                requestCount: 0,
                evidenceComponents: [
                    "config-before-after=\(result.configHash)",
                ],
                result: result,
                schemaID: schemaID,
                profile: profile,
                profileHash: profileHash,
                transactionID: transactionID
            ),
        ]
        return try appendAndReload(receipts)
    }

    private func coreReceipt(
        kind: ProviderCapabilityProbeKind,
        evidenceLevel: ProviderProbeEvidenceLevel,
        responseStructureSHA256: String?,
        requestCount: Int,
        evidenceComponents: [String],
        result: V011CurrentConnectionVerification,
        schemaID: String,
        profile: CodexRelayProfile,
        profileHash: String,
        transactionID: String
    ) throws -> ProviderCapabilityProbeReceipt {
        try ProviderCapabilityProbeReceiptFactory.issue(
            kind: kind,
            status: .verified,
            providerID: result.providerID,
            modelID: result.state.model,
            codexContractID: schemaID,
            transactionID: transactionID,
            observedAt: result.verifiedAt,
            stage: ProviderProbeStageObservation(
                configured: "responses",
                emitted: "responses",
                accepted: "accepted",
                actual: kind == .responsesText ? "output" : nil,
                fallback: nil
            ),
            evidenceLevel: evidenceLevel,
            responseStructureSHA256: responseStructureSHA256,
            evidenceComponents: evidenceComponents,
            requestCount: requestCount,
            userConsented: false,
            containsSensitiveEvidence: false,
            profileID: profile.id,
            capabilityProfileSHA256: profileHash
        )
    }
}
