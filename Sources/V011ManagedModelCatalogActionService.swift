import Foundation

enum V011ManagedModelCatalogActionInput {
    case payload(Data, sourceName: String)
    case external(Build65CatalogCopyRequest)
}

struct V011ManagedModelCatalogActionRequest: @unchecked Sendable {
    let input: V011ManagedModelCatalogActionInput
    let sourceProfile: CodexRelayProfile
}

struct V011ManagedModelCatalogActionResult: @unchecked Sendable {
    let targetProfile: CodexRelayProfile
    let allReceipts: [ProviderCapabilityProbeReceipt]
}

enum V011ManagedModelCatalogActionOutcome: @unchecked Sendable {
    case success(V011ManagedModelCatalogActionResult)
    case failure(status: String, errorMessage: String)
}

/// Owns external-file revalidation, managed catalog import, and matching
/// capability-evidence persistence. MainActor controller owns action lifetime;
/// its façade delegate projects UI and starts existing profile transaction.
struct V011ManagedModelCatalogActionService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func execute(
        _ request: V011ManagedModelCatalogActionRequest
    ) async -> V011ManagedModelCatalogActionOutcome {
        let dependencies = dependencies
        return await Task.detached(priority: .userInitiated) {
            do {
                let source = try Self.catalogSource(
                    from: request.input
                )
                let imported = try
                    V011ManagedModelCatalogImportService(
                        controlRoot: dependencies.controlRoot,
                        versionDiscovery:
                            dependencies.versionDiscovery
                    ).importCatalog(
                        payload: source.payload,
                        sourceName: source.name,
                        sourceProfile: request.sourceProfile
                    )
                let receipts = try
                    V011ProviderCapabilityEvidenceService(
                        controlRoot: dependencies.controlRoot,
                        keyProvider: dependencies.keyProvider
                    ).appendAndReload([imported.probeReceipt])
                return .success(
                    V011ManagedModelCatalogActionResult(
                        targetProfile: imported.targetProfile,
                        allReceipts: receipts
                    )
                )
            } catch {
                return .failure(
                    status:
                        "受管模型目录未应用；当前Codex设置未改变",
                    errorMessage: error.localizedDescription
                )
            }
        }.value
    }

    private static func catalogSource(
        from input: V011ManagedModelCatalogActionInput
    ) throws -> (payload: Data, name: String) {
        switch input {
        case let .payload(payload, sourceName):
            return (payload, sourceName)
        case let .external(request):
            let sourceURL = request.sourceURL.standardizedFileURL
            let values = try sourceURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw ManagedModelCatalogStoreError.unsafeFile
            }
            let payload = try Data(
                contentsOf: sourceURL,
                options: .mappedIfSafe
            )
            if let expectedHash = request.payloadSHA256,
               ManagedModelCatalogStore.sha256(payload)
                    != expectedHash {
                throw ManagedModelCatalogStoreError
                    .payloadHashMismatch
            }
            return (payload, sourceURL.lastPathComponent)
        }
    }
}
