// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceOfficialRestoreRequest {
    let runtimeMode: CodexRuntimeMode
    let additionalRecoveryFiles:
        [SessionAdditionalRecoveryFile]
}

enum ConfigWorkspaceOfficialRestoreDisposition {
    case committed
    case rolledBack(errorMessage: String)
    case invalidOfficialBaseline(errorMessage: String)
    case manualRecovery(errorMessage: String)
}

struct ConfigWorkspaceOfficialRestoreResult {
    let disposition:
        ConfigWorkspaceOfficialRestoreDisposition
    let runtimeMode: CodexRuntimeMode
}

/// Owns official-mode restore, SessionSync coordination, and rollback. Model
/// keeps saved-work authorization, busy lifetime, and Published presentation.
@MainActor
struct ConfigWorkspaceOfficialRestoreService {
    let application: CodexApplicationController
    let stateStore: CodexStateStore
    let switchEngine: CodexSwitchEngine
    let sessionEngine: SessionSyncEngine

    func execute(
        _ request: ConfigWorkspaceOfficialRestoreRequest,
        reportStatus: (String) -> Void
    ) async -> ConfigWorkspaceOfficialRestoreResult {
        var recoveryPoint: CodexSwitchRecoveryPoint?
        var sessionTransactionID: String?
        var runtimeMode = request.runtimeMode
        do {
            try switchEngine.validateOfficialRestoreTarget()
            reportStatus("正在正常请求Codex退出")
            if application.isRunning {
                try await application.requestQuit()
            }
            let beforeState = try stateStore.load()
            recoveryPoint = try switchEngine
                .createRecoveryPoint()
            let sessionPreview = try sessionEngine.preview(
                targetProvider: "openai",
                targetProfileID: "official",
                sourceProfileID: beforeState.activeRelayID,
                trustSourceOrigin:
                    beforeState.currentMode != .external,
                additionalRecoveryFiles:
                    request.additionalRecoveryFiles
            )
            guard sessionPreview.canApply else {
                throw SessionSyncError.planBlocked(
                    sessionPreview.blockers
                )
            }
            let prepared = try sessionEngine.prepare(
                sessionPreview
            )
            sessionTransactionID = prepared.id
            _ = try switchEngine.restoreOfficial()
            let applied = try sessionEngine.apply(
                transactionID: prepared.id
            )
            guard applied.phase == .readyToCommit else {
                throw SessionSyncError
                    .invalidTransactionPhase(applied.phase)
            }
            try await application.launch()
            _ = try sessionEngine.commit(
                transactionID: prepared.id,
                message:
                    "已切到官方并保持全部历史会话可见"
            )
            runtimeMode = .official
            return ConfigWorkspaceOfficialRestoreResult(
                disposition: .committed,
                runtimeMode: runtimeMode
            )
        } catch {
            let originalError = error
            do {
                if application.isRunning {
                    try await application.requestQuit()
                }
                if let sessionTransactionID,
                   let transaction = try? sessionEngine
                    .journalStore.load(
                        sessionTransactionID
                    ),
                   transaction.phase != .rolledBack,
                   transaction.phase != .manualRecovery,
                   transaction.phase != .committed {
                    _ = try sessionEngine.rollback(
                        transactionID: sessionTransactionID,
                        reason:
                            originalError.localizedDescription
                    )
                }
                if let recoveryPoint {
                    _ = try switchEngine
                        .restoreRecoveryPoint(recoveryPoint)
                    runtimeMode =
                        recoveryPoint.state.currentMode
                    if runtimeMode != .external {
                        try await application.launch()
                    }
                }
            } catch let recoveryError {
                return ConfigWorkspaceOfficialRestoreResult(
                    disposition: .manualRecovery(
                        errorMessage:
                            "原错误："
                            + originalError
                                .localizedDescription
                            + "；恢复阻止："
                            + recoveryError
                                .localizedDescription
                    ),
                    runtimeMode: runtimeMode
                )
            }
            if case CodexControlError
                .officialBaselineContainsRelay =
                    originalError {
                return ConfigWorkspaceOfficialRestoreResult(
                    disposition: .invalidOfficialBaseline(
                        errorMessage:
                            "恢复官方模式失败："
                            + originalError
                                .localizedDescription
                    ),
                    runtimeMode: runtimeMode
                )
            }
            return ConfigWorkspaceOfficialRestoreResult(
                disposition: .rolledBack(
                    errorMessage:
                        "恢复官方模式失败："
                        + originalError.localizedDescription
                ),
                runtimeMode: runtimeMode
            )
        }
    }
}
