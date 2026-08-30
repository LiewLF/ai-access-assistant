import Foundation

@MainActor
protocol V011CapabilityEvidenceControllerDelegate: AnyObject {
    var allowsCapabilityEvidenceActionStart: Bool { get }
    var hasPendingRecovery: Bool { get }
    var managedState: V011ManagedState { get }
    var currentProviderID: String? { get }
    var currentCodexContractID: String? { get }
    var currentRelayProfile: CodexRelayProfile? { get }

    func capabilityEvidencePendingRecoveryBlockMessage(
        action: String
    ) -> String
    func capabilityEvidenceActionDidReject(_ message: String)
    func capabilityEvidenceOptionalProbeDidReject(_ message: String)
    func capabilityEvidenceValidateOptionalProbeExpectation(
        _ expected: V011OptionalProviderProbeExpectation
    ) throws
    func capabilityEvidenceOptionalProbeDidBegin(
        kind: ProviderCapabilityProbeKind
    )
    func capabilityEvidenceOptionalProbeDidSucceed(
        _ result: V011OptionalProviderProbeActionResult
    )
    func capabilityEvidenceOptionalProbeDidFail(
        _ message: String
    )
    func capabilityEvidenceOptionalProbeDidBecomeIdle()
    func capabilityEvidenceCatalogImportDidBegin()
    func capabilityEvidenceCatalogImportDidReceive(
        request: V011ManagedModelCatalogActionRequest,
        outcome: V011ManagedModelCatalogActionOutcome
    )
}

/// Owns optional-probe and managed-catalog action gates, CAS callbacks, task
/// launch, and completion ordering. Evidence services retain durable writes.
@MainActor
final class V011CapabilityEvidenceController {
    private weak var delegate:
        (any V011CapabilityEvidenceControllerDelegate)?
    private let optionalProbeService:
        V011OptionalProviderProbeActionService
    private let catalogService: V011ManagedModelCatalogActionService

    init(
        dependencies: V011AccessDependencies,
        delegate: any V011CapabilityEvidenceControllerDelegate
    ) {
        optionalProbeService =
            V011OptionalProviderProbeActionService(
                dependencies: dependencies
            )
        catalogService = V011ManagedModelCatalogActionService(
            dependencies: dependencies
        )
        self.delegate = delegate
    }

    func runOptionalProbe(
        _ kind: ProviderCapabilityProbeKind,
        userConsented: Bool
    ) {
        guard let delegate,
              delegate.allowsCapabilityEvidenceActionStart else {
            return
        }
        let prepared: V011OptionalProviderProbePrepared
        do {
            prepared = try optionalProbeService.prepare(
                kind: kind,
                userConsented: userConsented,
                currentProviderID: delegate.currentProviderID,
                currentContractID: delegate.currentCodexContractID,
                managedState: delegate.managedState
            )
        } catch {
            delegate.capabilityEvidenceOptionalProbeDidReject(
                error.localizedDescription
            )
            return
        }
        delegate.capabilityEvidenceOptionalProbeDidBegin(kind: kind)
        let service = optionalProbeService
        Task {
            do {
                let result = try await service.execute(
                    prepared,
                    validateCurrentState: { expected in
                        try delegate
                            .capabilityEvidenceValidateOptionalProbeExpectation(
                                expected
                            )
                    }
                )
                delegate.capabilityEvidenceOptionalProbeDidSucceed(
                    result
                )
            } catch {
                delegate.capabilityEvidenceOptionalProbeDidFail(
                    error.localizedDescription
                )
            }
            delegate
                .capabilityEvidenceOptionalProbeDidBecomeIdle()
        }
    }

    func importCatalog(
        payload: Data,
        sourceName: String,
        sourceProfile: CodexRelayProfile
    ) {
        performCatalogImport(
            V011ManagedModelCatalogActionRequest(
                input: .payload(payload, sourceName: sourceName),
                sourceProfile: sourceProfile
            )
        )
    }

    func copyExternalCatalog(
        _ request: Build65CatalogCopyRequest
    ) {
        guard let delegate else { return }
        guard let profile = delegate.currentRelayProfile,
              profile.id == request.profileID,
              profile.v011ProviderID == request.providerID,
              delegate.currentCodexContractID
                == request.codexContractID,
              request.selectedModelID.map({
                  profile.defaultModel == $0
              }) ?? true else {
            delegate.capabilityEvidenceActionDidReject(
                "当前Provider、模型或版本合同已变化；请重新核对目录"
            )
            return
        }
        performCatalogImport(
            V011ManagedModelCatalogActionRequest(
                input: .external(request),
                sourceProfile: profile
            )
        )
    }

    private func performCatalogImport(
        _ request: V011ManagedModelCatalogActionRequest
    ) {
        guard let delegate,
              delegate.allowsCapabilityEvidenceActionStart else {
            return
        }
        guard !delegate.hasPendingRecovery else {
            delegate.capabilityEvidenceActionDidReject(
                delegate.capabilityEvidencePendingRecoveryBlockMessage(
                    action: "导入受管模型目录"
                )
            )
            return
        }
        guard delegate.managedState.relayProfiles
                .contains(request.sourceProfile) else {
            delegate.capabilityEvidenceActionDidReject(
                "中转档已变化；请刷新后重新选择模型目录"
            )
            return
        }
        delegate.capabilityEvidenceCatalogImportDidBegin()
        let service = catalogService
        Task {
            let outcome = await service.execute(request)
            delegate.capabilityEvidenceCatalogImportDidReceive(
                request: request,
                outcome: outcome
            )
        }
    }
}
