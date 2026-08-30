// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceConfigurationHealthRequest {
    let runtimeTruth: RuntimeTruth?
    let expectedAgentVersion: String?
    let expectedProviderID: String?
    let expectedCodexContractID: String?
    let expectedProfileID: String?
    let expectedCapabilityProfileSHA256: String?
    let providerProbeReceipts:
        [ProviderCapabilityProbeReceipt]
}

/// Owns configuration-health evidence loading and evaluator input assembly.
struct ConfigWorkspaceConfigurationHealthService {
    let codexHomeURL: URL
    let controlRootURL: URL
    let adapter: CodexConfigurationAdapter
    let stateStore: CodexStateStore

    func evaluate(
        _ request: ConfigWorkspaceConfigurationHealthRequest
    ) throws -> ConfigurationHealthReport {
        let state = try stateStore.load()
        let text = String(
            decoding:
                try adapter.currentConfigData() ?? Data(),
            as: UTF8.self
        )
        let parsedDocument = try TOMLSemanticEngine.parse(
            TOMLSensitiveValueRedactor.redact(text)
        )
        let catalogInspection = parsedDocument.rootString(
            "model_catalog_json"
        ).map { path in
            Build65CatalogInspector.inspect(
                catalogPath: path,
                store: ManagedModelCatalogStore(
                    rootURL: controlRootURL
                        .appendingPathComponent(
                            "V011/ManagedModelCatalogs",
                            isDirectory: true
                        )
                ),
                configProviderID: parsedDocument.rootString(
                    "model_provider"
                ),
                configContractID:
                    request.expectedCodexContractID,
                selectedModelID:
                    parsedDocument.rootString("model")
            )
        }
        return ConfigurationHealthEvaluator.evaluate(
            configText: text,
            runtimeTruth: request.runtimeTruth,
            lastTransaction: state.lastTransaction,
            capabilityEvidence:
                ConfigurationCapabilityInspector.inspect(
                    codexHome: codexHomeURL,
                    configText: text,
                    providerProbeReceipts:
                        request.providerProbeReceipts
                ),
            expectedAgentBundleIdentifier: "com.openai.codex",
            expectedAgentVersion:
                request.expectedAgentVersion,
            expectedProviderID: request.expectedProviderID,
            expectedCodexContractID:
                request.expectedCodexContractID,
            expectedProfileID: request.expectedProfileID,
            expectedCapabilityProfileSHA256:
                request.expectedCapabilityProfileSHA256,
            catalogInspection: catalogInspection
        )
    }
}
