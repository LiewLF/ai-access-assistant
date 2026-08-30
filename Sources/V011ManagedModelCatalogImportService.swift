import Foundation

struct V011ManagedModelCatalogImportResult: @unchecked Sendable {
    let targetProfile: CodexRelayProfile
    let probeReceipt: ProviderCapabilityProbeReceipt
}

/// Owns validation and durable copy of a user-selected model catalog plus
/// construction of matching declared-evidence receipt.
struct V011ManagedModelCatalogImportService: @unchecked Sendable {
    private let controlRoot: URL
    private let versionDiscovery: any FableCodexVersionDiscovering

    init(
        controlRoot: URL,
        versionDiscovery: any FableCodexVersionDiscovering
    ) {
        self.controlRoot = controlRoot
        self.versionDiscovery = versionDiscovery
    }

    func importCatalog(
        payload: Data,
        sourceName: String,
        sourceProfile: CodexRelayProfile
    ) throws -> V011ManagedModelCatalogImportResult {
        let providerID = sourceProfile.v011ProviderID
        let defaultModel = sourceProfile.defaultModel
        let safeSourceName = URL(
            fileURLWithPath: sourceName
        ).lastPathComponent
        let installation = try versionDiscovery.discover()
        guard case let .verified(schemaID) = installation.support,
              installation.contractEntry?.schemaID == schemaID else {
            throw FableSwitchError.unsupportedVersion
        }
        let store = ManagedModelCatalogStore(
            rootURL: controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent(
                    "ManagedModelCatalogs",
                    isDirectory: true
                )
        )
        let parsedModels = try store.parseModels(payload)
        guard parsedModels.contains(where: {
            $0.modelID == defaultModel
        }) else {
            throw ManagedModelCatalogStoreError
                .invalidModel(defaultModel)
        }
        let payloadHash = ManagedModelCatalogStore.sha256(payload)
        let receipt = try store.save(
            providerID: providerID,
            payload: payload,
            codexContractID: schemaID,
            source: ManagedModelCatalogSource(
                kind: .userFile,
                locator: safeSourceName,
                evidenceID: "sha256:\(payloadHash)"
            )
        )
        guard receipt.metadata.providerID == providerID,
              receipt.metadata.codexContractID == schemaID,
              receipt.metadata.models.contains(where: {
                  $0.modelID == defaultModel
              }) else {
            throw ManagedModelCatalogStoreError
                .invalidModel(defaultModel)
        }
        let capability = sourceProfile.effectiveCapabilityProfile
            .withManagedModelCatalog(
                path: receipt.catalogURL.path,
                models: receipt.metadata.models
            )
        let targetProfile = sourceProfile
            .updatingCapabilityProfile(capability)
        let profileHash = try ProviderCapabilityProfileIdentity
            .sha256(capability)
        let probeReceipt = try ProviderCapabilityProbeReceiptFactory.issue(
            kind: .modelCatalog,
            status: .verified,
            providerID: providerID,
            modelID: defaultModel,
            codexContractID: receipt.metadata.codexContractID,
            transactionID:
                "catalog-\(receipt.metadata.payloadSHA256)",
            observedAt: receipt.metadata.generatedAt,
            stage: ProviderProbeStageObservation(
                configured: "managed-copy",
                emitted: receipt.metadata.payloadSHA256,
                accepted: "validated",
                actual: receipt.metadata.payloadSHA256,
                fallback: nil
            ),
            evidenceLevel: .declared,
            responseStructureSHA256:
                receipt.metadata.payloadSHA256,
            evidenceComponents: [
                "source=validated-user-file",
                "models=\(receipt.metadata.models.count)",
                "default-model=\(defaultModel)",
                "managed-path-sha256="
                    + ProviderCapabilityProbeReceiptFactory.sha256(
                        Data(receipt.catalogURL.path.utf8)
                    ),
            ],
            requestCount: 0,
            userConsented: false,
            containsSensitiveEvidence: false,
            profileID: sourceProfile.id,
            capabilityProfileSHA256: profileHash
        )
        return V011ManagedModelCatalogImportResult(
            targetProfile: targetProfile,
            probeReceipt: probeReceipt
        )
    }
}
