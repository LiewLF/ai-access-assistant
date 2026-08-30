// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

@MainActor
protocol ConfigWorkspaceSessionRepairControllerDelegate:
    AnyObject {
    func configWorkspaceSessionRepairDidReportStatus(
        _ status: String
    )
    func configWorkspaceSessionRepairDidReportProgress(
        phase: SessionSyncPhase,
        status: String
    )
    func configWorkspaceSessionRepairDidFinish(
        _ result: ConfigWorkspaceSessionRepairResult
    )
    func configWorkspaceSessionRestoreDidFinish(
        _ result: ConfigWorkspaceSessionRestoreResult
    )
    func configWorkspacePendingSessionRecoveryDidFinish(
        _ result:
            ConfigWorkspacePendingSessionRecoveryResult
    )
}

/// Owns Task lifetime for user-authorized SessionSync mutations. Transaction
/// ordering stays in ConfigWorkspaceSessionRepairService; model remains sole
/// owner of authorization gates and Published state.
@MainActor
final class ConfigWorkspaceSessionRepairController {
    private let codexHomeURL: URL
    private let controlRootURL: URL
    private let keyProvider: () throws -> Data
    private weak var delegate:
        (any ConfigWorkspaceSessionRepairControllerDelegate)?
    private var task: Task<Void, Never>?

    init(
        codexHomeURL: URL,
        controlRootURL: URL,
        keyProvider: @escaping () throws -> Data,
        delegate:
            any ConfigWorkspaceSessionRepairControllerDelegate
    ) {
        self.codexHomeURL = codexHomeURL
        self.controlRootURL = controlRootURL
        self.keyProvider = keyProvider
        self.delegate = delegate
    }

    func repair(
        application: CodexApplicationController,
        resolveTarget: @escaping @MainActor
            () throws -> ConfigWorkspaceSessionRepairTarget,
        additionalRecoveryFiles:
            [SessionAdditionalRecoveryFile]
    ) {
        let service = ConfigWorkspaceSessionRepairService(
            engine: makeEngine(),
            application: application
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let result = await service.repair(
                resolveTarget: resolveTarget,
                additionalRecoveryFiles:
                    additionalRecoveryFiles,
                reportStatus: { [weak self] status in
                    self?.delegate?
                        .configWorkspaceSessionRepairDidReportStatus(
                            status
                        )
                }
            )
            delegate?.configWorkspaceSessionRepairDidFinish(
                result
            )
        }
    }

    func restoreLatest(
        application: CodexApplicationController
    ) {
        let service = ConfigWorkspaceSessionRepairService(
            engine: makeEngine(),
            application: application
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let result = await service.restoreLatest()
            delegate?.configWorkspaceSessionRestoreDidFinish(
                result
            )
        }
    }

    func recoverPending(
        application: CodexApplicationController
    ) {
        let service = ConfigWorkspaceSessionRepairService(
            engine: makeEngine(),
            application: application
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer { task = nil }
            let result = await service.recoverPending()
            delegate?
                .configWorkspacePendingSessionRecoveryDidFinish(
                    result
                )
        }
    }

    private func makeEngine() -> SessionSyncEngine {
        SessionSyncEngine(
            codexHomeURL: codexHomeURL,
            controlRootURL: controlRootURL,
            keyProvider: keyProvider,
            progressObserver: {
                [weak self] phase, message in
                Task { @MainActor [weak self] in
                    self?.delegate?
                        .configWorkspaceSessionRepairDidReportProgress(
                            phase: phase,
                            status: message
                        )
                }
            }
        )
    }
}
