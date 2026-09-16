// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceRelaySwitchRequest {
    let accessRoute: AccessRouteKind
    let runtimeMode: CodexRuntimeMode
    let profile: CodexRelayProfile
    let providerName: String
    let plan: CodexConfigurationPlan
    let normalizesExistingProvider: Bool
    let existingProviderImportReport:
        ExistingProviderImportReport?
    let externalAdoptionExpectedConfigHash: String?
    let officialBaseline: OfficialBaseline?
    let enteredAPIKey: String
    let additionalRecoveryFiles:
        [SessionAdditionalRecoveryFile]
    let savedRelayProfiles: [CodexRelayProfile]
}

enum ConfigWorkspaceRelaySwitchEvent {
    case phase(RealSwitchPhase)
    case status(String)
}

enum ConfigWorkspaceRelaySwitchDisposition {
    case committed(validationMessage: String)
    case rolledBack(errorMessage: String)
    case manualRecovery(errorMessage: String)
}

struct ConfigWorkspaceRelaySwitchResult {
    let disposition: ConfigWorkspaceRelaySwitchDisposition
    let runtimeMode: CodexRuntimeMode
    let officialBaseline: OfficialBaseline?
    let savedRelayProfiles: [CodexRelayProfile]
    let existingProviderImportReport:
        ExistingProviderImportReport?
    let hasPendingSessionRecovery: Bool
}

/// Owns relay cutover, SessionSync commit, credential compensation, and
/// connection validation as one transaction. ConfigWorkspaceModel keeps user
/// authorization, busy state, and Published presentation.
@MainActor
struct ConfigWorkspaceRelaySwitchService {
    let application: CodexApplicationController
    let adapter: CodexConfigurationAdapter
    let stateStore: CodexStateStore
    let switchEngine: CodexSwitchEngine
    let sessionEngine: SessionSyncEngine

    func execute(
        _ request: ConfigWorkspaceRelaySwitchRequest,
        reportEvent:
            (ConfigWorkspaceRelaySwitchEvent) -> Void
    ) async -> ConfigWorkspaceRelaySwitchResult {
        var recoveryPoint: CodexSwitchRecoveryPoint?
        var sessionTransactionID: String?
        var previousTargetSecret: String?
        var targetSecretChanged = false
        var runtimeMode = request.runtimeMode
        var officialBaseline = request.officialBaseline
        var savedRelayProfiles = request.savedRelayProfiles
        var importReport =
            request.existingProviderImportReport

        do {
            reportEvent(.phase(.preflight))
            let writers =
                ConfigurationWriterProcessInspector
                    .runningWriters()
            guard writers.isEmpty else {
                throw CodexControlError
                    .configurationWritersRunning(writers)
            }
            reportEvent(
                .status("正在正常请求Codex退出")
            )
            if application.isRunning {
                try await application.requestQuit()
            }
            let beforeState = try stateStore.load()
            if request.accessRoute != .manual {
                recoveryPoint = try switchEngine
                    .createRecoveryPoint()
            }
            let targetProvider = request.profile.providerID
                ?? PreservingTOMLEditor
                    .providerIdentifier(
                        request.profile.id
                    )
            let sourceProfileID: String?
            switch beforeState.currentMode {
            case .official:
                sourceProfileID = "official"
            case .relay:
                sourceProfileID = beforeState.activeRelayID
            case .external:
                sourceProfileID = nil
            }
            let sessionPreview = try sessionEngine.preview(
                targetProvider: targetProvider,
                targetProfileID: request.profile.id,
                sourceProfileID: sourceProfileID,
                trustSourceOrigin:
                    !request.normalizesExistingProvider
                        && beforeState.currentMode
                            != .external,
                additionalRecoveryFiles:
                    request.additionalRecoveryFiles
            )
            guard sessionPreview.canApply else {
                throw SessionSyncError.planBlocked(
                    sessionPreview.blockers
                )
            }
            let preparedSessions =
                try sessionEngine.prepare(sessionPreview)
            sessionTransactionID = preparedSessions.id

            previousTargetSecret =
                try? RelaySecretStore.load(
                    relayID: request.profile.id
                )
            let enteredKey = request.enteredAPIKey
                .trimmingCharacters(
                    in: .whitespacesAndNewlines
                )
            let key: String
            if !enteredKey.isEmpty {
                key = enteredKey
            } else if request.normalizesExistingProvider,
                      request.existingProviderImportReport?
                        .legacyBearerFieldPresent == true {
                key = try adapter.legacyBearerForMigration(
                    profile: request.profile
                )
            } else {
                key = try RelaySecretStore.load(
                    relayID: request.profile.id
                )
            }
            if previousTargetSecret != key {
                try RelaySecretStore.save(
                    key,
                    relayID: request.profile.id
                )
                targetSecretChanged = true
            }

            if request.accessRoute == .manual
                && !request.normalizesExistingProvider {
                guard try adapter.manualConfigurationMatches(
                    request.profile
                ) else {
                    throw CodexControlError
                        .manualConfigurationMismatch
                }
                _ = try switchEngine.adoptManualRelay(
                    profile: request.profile
                )
            } else {
                let expectedHash =
                    request.normalizesExistingProvider
                    ? (
                        request
                            .externalAdoptionExpectedConfigHash
                            ?? request
                                .existingProviderImportReport?
                                .configHashBefore
                    )
                    : (
                        request.plan.original.isEmpty
                            ? nil
                            : SecureProfileVault.sha256(
                                Data(
                                    request.plan.original.utf8
                                )
                            )
                    )
                if request.accessRoute == .managed,
                   runtimeMode == .official {
                    let currentHash = try adapter
                        .currentConfigHash()
                    if expectedHash != nil,
                       currentHash != expectedHash {
                        throw CodexControlError.externalDrift
                    }
                    officialBaseline = try switchEngine
                        .createOfficialBaseline()
                }
                if request.normalizesExistingProvider,
                   let officialBaseline {
                    try adapter.restoreAuthentication(
                        officialBaseline
                    )
                }
                reportEvent(.phase(.write))
                _ = try switchEngine.applyRelay(
                    profile: request.profile,
                    expectedCurrentHash: expectedHash,
                    configurationPlan: request.plan
                )
            }

            let appliedSessions = try sessionEngine.apply(
                transactionID: preparedSessions.id
            )
            guard appliedSessions.phase
                    == .readyToCommit else {
                throw SessionSyncError
                    .invalidTransactionPhase(
                        appliedSessions.phase
                    )
            }
            reportEvent(.phase(.launch))
            reportEvent(
                .status(
                    "正在通过持久凭据桥启动Codex"
                )
            )
            try await application.launch()
            reportEvent(.phase(.validate))
            reportEvent(
                .status(
                    "正在对指定模型发送最小真实请求"
                )
            )
            // LTP-130: the live switch uses the same specified-model probe as
            // saved-relay add and switch preflight. The /models directory is
            // an independent discovery and is never a precondition here.
            let validation = try await
                V011AccessDependencies.verifyDraftSpecifiedModel(
                    profile: request.profile,
                    apiKey: key
                )
            try recordSpecifiedModelProbeValidation(
                for: request.profile
            )
            _ = try switchEngine.completeRelayValidation(
                message: validation
            )
            _ = try sessionEngine.commit(
                transactionID: preparedSessions.id,
                message: "切轨与历史会话同步均已验证"
            )
            runtimeMode = .relay
            savedRelayProfiles =
                (try? stateStore.load().relayProfiles)
                ?? savedRelayProfiles
            if request.normalizesExistingProvider {
                importReport = try? adapter
                    .inspectExistingProvider(
                        displayName: request.providerName
                    ).report
            }
            return ConfigWorkspaceRelaySwitchResult(
                disposition: .committed(
                    validationMessage: validation
                ),
                runtimeMode: runtimeMode,
                officialBaseline: officialBaseline,
                savedRelayProfiles: savedRelayProfiles,
                existingProviderImportReport: importReport,
                hasPendingSessionRecovery: false
            )
        } catch {
            let originalError = error
            reportEvent(
                .status("切换失败，正在整笔恢复")
            )
            let disposition:
                ConfigWorkspaceRelaySwitchDisposition
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
                if request.accessRoute == .manual,
                   !request.normalizesExistingProvider {
                    _ = try switchEngine.restoreOfficial()
                    runtimeMode = .official
                } else if let recoveryPoint {
                    _ = try switchEngine
                        .restoreRecoveryPoint(recoveryPoint)
                    runtimeMode =
                        recoveryPoint.state.currentMode
                }
                if targetSecretChanged {
                    if let previousTargetSecret {
                        try RelaySecretStore.save(
                            previousTargetSecret,
                            relayID: request.profile.id
                        )
                    } else {
                        try RelaySecretStore.delete(
                            relayID: request.profile.id
                        )
                    }
                }
                if runtimeMode != .external {
                    try await application.launch()
                }
                disposition = .rolledBack(
                    errorMessage:
                        originalError.localizedDescription
                )
            } catch let recoveryError {
                disposition = .manualRecovery(
                    errorMessage:
                        "原错误："
                        + originalError.localizedDescription
                        + "；恢复阻止："
                        + recoveryError.localizedDescription
                        + "。请勿继续切轨。"
                )
            }
            return ConfigWorkspaceRelaySwitchResult(
                disposition: disposition,
                runtimeMode: runtimeMode,
                officialBaseline: officialBaseline,
                savedRelayProfiles: savedRelayProfiles,
                existingProviderImportReport: importReport,
                hasPendingSessionRecovery:
                    (try? sessionEngine.journalStore
                        .pending().isEmpty) == false
            )
        }
    }

    /// LTP-130: a successful switch only proves the specified-model probe. No
    /// catalog read happens on this path, so the probe schedule must not
    /// record a model-list pass here.
    private func recordSpecifiedModelProbeValidation(
        for profile: CodexRelayProfile
    ) throws {
        guard let entryID = profile.catalogEntryID else {
            return
        }
        _ = try RelayProbeScheduleStore()
            .recordSpecifiedModelProbeSuccess(entryID: entryID)
    }
}
