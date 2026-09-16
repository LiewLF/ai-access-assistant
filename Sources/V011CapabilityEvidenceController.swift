import Foundation

enum V011CapabilityEvidenceReloadResult: Sendable {
    case loaded([ProviderCapabilityProbeReceipt])
    case failed(String)
}

@MainActor
protocol V011CapabilityEvidenceControllerDelegate: AnyObject {
    var allowsCapabilityEvidenceActionStart: Bool { get }
    var hasPendingRecovery: Bool { get }
    var managedState: V011ManagedState { get }
    var currentProviderID: String? { get }
    var currentCodexContractID: String? { get }
    var currentRelayProfile: CodexRelayProfile? { get }

    func capabilityEvidenceReceiptReloadDidReceive(
        _ result: V011CapabilityEvidenceReloadResult
    )
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
    private let controlRoot: URL
    private let keyProvider: @Sendable () throws -> Data
    private var receiptReloadTask: Task<Void, Never>?
    private var receiptReloadTimeoutTask: Task<Void, Never>?
    private var receiptReloadGeneration: UInt64 = 0
    private var receiptReloadRequested = false

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
        controlRoot = dependencies.controlRoot
        keyProvider = dependencies.keyProvider
    }

    var hasPendingReceiptRead: Bool { receiptReloadTask != nil }

    /// Optional receipt I/O must never hold the main actor or core refresh.
    /// A blocked OS call keeps one worker; timeout does not launch a replacement.
    func reloadReceipts() {
        receiptReloadGeneration &+= 1
        receiptReloadRequested = true
        let generation = receiptReloadGeneration
        receiptReloadTimeoutTask?.cancel()
        receiptReloadTimeoutTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 5_000_000_000) }
            catch { return }
            guard let self, self.receiptReloadGeneration == generation else { return }
            self.invalidateReceiptReload()
            self.delegate?.capabilityEvidenceReceiptReloadDidReceive(.failed(
                "扩展能力验证记录暂未读完；当前接入状态已保留，可稍后重新读取。"
            ))
        }
        startReceiptReloadIfPossible()
    }

    /// A newer durable result must win over a read that captured older bytes.
    func invalidateReceiptReload() {
        receiptReloadGeneration &+= 1
        receiptReloadRequested = false
        receiptReloadTimeoutTask?.cancel()
        receiptReloadTimeoutTask = nil
    }

    private func startReceiptReloadIfPossible() {
        guard receiptReloadTask == nil, receiptReloadRequested else { return }
        receiptReloadRequested = false
        let generation = receiptReloadGeneration
        let controlRoot = controlRoot
        let keyProvider = keyProvider
        receiptReloadTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                do {
                    let receipts = try V011ProviderCapabilityEvidenceService(
                        controlRoot: controlRoot, keyProvider: keyProvider
                    ).load()
                    return V011CapabilityEvidenceReloadResult.loaded(receipts)
                } catch {
                    return V011CapabilityEvidenceReloadResult.failed(
                        "扩展能力验证记录无法读取：" + error.localizedDescription
                    )
                }
            }.value
            guard let self else { return }
            self.receiptReloadTask = nil
            if self.receiptReloadGeneration == generation {
                self.receiptReloadTimeoutTask?.cancel()
                self.receiptReloadTimeoutTask = nil
                self.delegate?.capabilityEvidenceReceiptReloadDidReceive(result)
            }
            self.startReceiptReloadIfPossible()
        }
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
