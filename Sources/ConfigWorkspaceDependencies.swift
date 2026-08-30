// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceDependencies {
    let codexHomeURL: URL?
    let controlRootURL: URL?
    let vaultKeyProvider: () throws -> Data
    let loadsControlStateOnInit: Bool
    let sessionPreviewOperation:
        (
            SessionSyncEngine,
            String,
            String,
            String?,
            Bool,
            [SessionAdditionalRecoveryFile]
        ) -> SessionPreviewScanOutcome

    static let live = ConfigWorkspaceDependencies(
        codexHomeURL: nil,
        controlRootURL: nil,
        vaultKeyProvider: AppVaultKeyStore.loadOrCreate,
        loadsControlStateOnInit: true,
        sessionPreviewOperation:
            liveSessionPreviewOperation
    )

    static let liveSessionPreviewOperation:
        (
            SessionSyncEngine,
            String,
            String,
            String?,
            Bool,
            [SessionAdditionalRecoveryFile]
        ) -> SessionPreviewScanOutcome = {
            engine,
            providerID,
            profileID,
            sourceProfileID,
            trustSourceOrigin,
            recoveryFiles in
            do {
                try Task.checkCancellation()
                let preview = try engine.preview(
                    targetProvider: providerID,
                    targetProfileID: profileID,
                    sourceProfileID:
                        sourceProfileID,
                    trustSourceOrigin:
                        trustSourceOrigin,
                    additionalRecoveryFiles:
                        recoveryFiles
                )
                try Task.checkCancellation()
                return .preview(preview)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(
                    error.localizedDescription
                )
            }
        }
}

enum SessionPreviewScanOutcome {
    case preview(SessionSyncPreview)
    case failed(String)
    case cancelled
}
