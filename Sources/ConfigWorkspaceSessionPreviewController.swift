// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceSessionPreviewRequest {
    let engine: SessionSyncEngine
    let providerID: String
    let profileID: String
    let trustSourceOrigin: Bool
    let recoveryFiles: [SessionAdditionalRecoveryFile]
    let operation:
        (
            SessionSyncEngine,
            String,
            String,
            String?,
            Bool,
            [SessionAdditionalRecoveryFile]
        ) -> SessionPreviewScanOutcome
}

@MainActor
protocol ConfigWorkspaceSessionPreviewControllerDelegate: AnyObject {
    func configWorkspaceSessionPreviewDidFinish(
        _ outcome: SessionPreviewScanOutcome
    )
}

/// Owns preview freshness, generation invalidation, cancellation propagation,
/// detached scan execution, and task lifetime. ConfigWorkspaceModel keeps
/// pending-journal/target guards and user-facing state projection.
@MainActor
final class ConfigWorkspaceSessionPreviewController {
    private weak var delegate:
        (any ConfigWorkspaceSessionPreviewControllerDelegate)?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastScannedAt: Date?

    var isRunning: Bool { task != nil }

    init(
        delegate: any ConfigWorkspaceSessionPreviewControllerDelegate
    ) {
        self.delegate = delegate
    }

    func hasFreshResult(
        hasPreview: Bool,
        now: Date = Date()
    ) -> Bool {
        guard hasPreview,
              let lastScannedAt else {
            return false
        }
        return now.timeIntervalSince(lastScannedAt) < 30
    }

    func scan(
        _ request: ConfigWorkspaceSessionPreviewRequest
    ) {
        cancel()
        let generation = UUID()
        self.generation = generation
        task = Task { [weak self] in
            let worker = Task.detached(
                priority: .userInitiated
            ) {
                request.operation(
                    request.engine,
                    request.providerID,
                    request.profileID,
                    request.profileID,
                    request.trustSourceOrigin,
                    request.recoveryFiles
                )
            }
            let outcome = await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
            guard let self,
                  generation == self.generation else {
                return
            }
            task = nil
            if case .preview = outcome {
                lastScannedAt = Date()
            }
            delegate?.configWorkspaceSessionPreviewDidFinish(
                outcome
            )
        }
    }

    func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
    }
}
