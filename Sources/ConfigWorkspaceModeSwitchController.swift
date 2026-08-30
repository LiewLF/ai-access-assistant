// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConfigWorkspaceModeSwitchFieldUpdate<Value> {
    case preserve
    case set(Value)
}

struct ConfigWorkspaceModeSwitchOutcome {
    let runtimeMode: CodexRuntimeMode
    let officialBaseline:
        ConfigWorkspaceModeSwitchFieldUpdate<
            OfficialBaseline?
        >
    let savedRelayProfiles:
        ConfigWorkspaceModeSwitchFieldUpdate<
            [CodexRelayProfile]
        >
    let existingProviderImportReport:
        ConfigWorkspaceModeSwitchFieldUpdate<
            ExistingProviderImportReport?
        >
    let hasPendingSessionRecovery:
        ConfigWorkspaceModeSwitchFieldUpdate<Bool>
    let phase: RealSwitchPhase
    let status: String
    let errorMessage: String?
    let clearsRuntimeDrift: Bool
    let refreshesRuntimeTruth: Bool
    let refreshesCredentialBridge: Bool
    let refreshesSessionPreview: Bool
}

@MainActor
protocol ConfigWorkspaceModeSwitchControllerDelegate:
    AnyObject {
    func configWorkspaceModeSwitchDidReceive(
        _ event: ConfigWorkspaceRelaySwitchEvent
    )
    func configWorkspaceModeSwitchDidFinish(
        _ outcome: ConfigWorkspaceModeSwitchOutcome
    )
    func configWorkspaceOfficialRestoreDidReportStatus(
        _ status: String
    )
    func configWorkspaceModeSwitchDidBecomeIdle(
        resetRelayInput: Bool
    )
}

/// Owns relay/official switch Task lifetime and completion ordering. Durable
/// cutover, validation, SessionSync, and rollback stay in existing services;
/// model remains sole authorization and Published-state owner.
@MainActor
final class ConfigWorkspaceModeSwitchController {
    private weak var delegate:
        (any ConfigWorkspaceModeSwitchControllerDelegate)?
    private var task: Task<Void, Never>?

    init(
        delegate:
            any ConfigWorkspaceModeSwitchControllerDelegate
    ) {
        self.delegate = delegate
    }

    func switchRelay(
        request: ConfigWorkspaceRelaySwitchRequest,
        application: CodexApplicationController,
        adapter: CodexConfigurationAdapter,
        stateStore: CodexStateStore,
        switchEngine: CodexSwitchEngine,
        sessionEngine: SessionSyncEngine
    ) {
        let service = ConfigWorkspaceRelaySwitchService(
            application: application,
            adapter: adapter,
            stateStore: stateStore,
            switchEngine: switchEngine,
            sessionEngine: sessionEngine
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                delegate?
                    .configWorkspaceModeSwitchDidBecomeIdle(
                        resetRelayInput: true
                    )
            }
            let result = await service.execute(
                request,
                reportEvent: { [weak self] event in
                    self?.delegate?
                        .configWorkspaceModeSwitchDidReceive(
                            event
                        )
                }
            )
            delegate?.configWorkspaceModeSwitchDidFinish(
                Self.relayOutcome(
                    result,
                    providerName: request.providerName
                )
            )
        }
    }

    func restoreOfficial(
        request: ConfigWorkspaceOfficialRestoreRequest,
        application: CodexApplicationController,
        stateStore: CodexStateStore,
        switchEngine: CodexSwitchEngine,
        sessionEngine: SessionSyncEngine
    ) {
        let service = ConfigWorkspaceOfficialRestoreService(
            application: application,
            stateStore: stateStore,
            switchEngine: switchEngine,
            sessionEngine: sessionEngine
        )
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                task = nil
                delegate?
                    .configWorkspaceModeSwitchDidBecomeIdle(
                        resetRelayInput: false
                    )
            }
            let result = await service.execute(
                request,
                reportStatus: { [weak self] status in
                    self?.delegate?
                        .configWorkspaceOfficialRestoreDidReportStatus(
                            status
                        )
                }
            )
            delegate?.configWorkspaceModeSwitchDidFinish(
                Self.officialOutcome(result)
            )
        }
    }

    private static func relayOutcome(
        _ result: ConfigWorkspaceRelaySwitchResult,
        providerName: String
    ) -> ConfigWorkspaceModeSwitchOutcome {
        let phase: RealSwitchPhase
        let status: String
        let errorMessage: String?
        let committed: Bool
        switch result.disposition {
        case let .committed(validationMessage):
            phase = .committed
            status =
                "\(validationMessage)；全部历史会话已同步；"
                + "当前为\(providerName)中转模式"
            errorMessage = nil
            committed = true
        case let .rolledBack(message):
            phase = .rolledBack
            status =
                "配置、SQLite、rollout和界面状态已恢复"
            errorMessage = message
            committed = false
        case let .manualRecovery(message):
            phase = .manualRecovery
            status = "自动恢复未完成；事务已停止"
            errorMessage = message
            committed = false
        }
        return ConfigWorkspaceModeSwitchOutcome(
            runtimeMode: result.runtimeMode,
            officialBaseline: .set(
                result.officialBaseline
            ),
            savedRelayProfiles: .set(
                result.savedRelayProfiles
            ),
            existingProviderImportReport: .set(
                result.existingProviderImportReport
            ),
            hasPendingSessionRecovery: .set(
                result.hasPendingSessionRecovery
            ),
            phase: phase,
            status: status,
            errorMessage: errorMessage,
            clearsRuntimeDrift: committed,
            refreshesRuntimeTruth: committed,
            refreshesCredentialBridge: committed,
            refreshesSessionPreview: committed
        )
    }

    private static func officialOutcome(
        _ result: ConfigWorkspaceOfficialRestoreResult
    ) -> ConfigWorkspaceModeSwitchOutcome {
        let phase: RealSwitchPhase
        let status: String
        let errorMessage: String?
        let committed: Bool
        switch result.disposition {
        case .committed:
            phase = .committed
            status =
                "官方配置已恢复；全部历史会话已同步。请发送一次官方请求完成基线验证"
            errorMessage = nil
            committed = true
        case let .rolledBack(message):
            phase = .rolledBack
            status = "切回官方失败；已恢复切换前模式"
            errorMessage = message
            committed = false
        case let .invalidOfficialBaseline(message):
            phase = .manualRecovery
            status =
                "旧官方基线实际是中转；已在退出Codex和写配置前停止"
            errorMessage = message
            committed = false
        case let .manualRecovery(message):
            phase = .manualRecovery
            status = "切回官方失败，自动恢复未完成"
            errorMessage = message
            committed = false
        }
        return ConfigWorkspaceModeSwitchOutcome(
            runtimeMode: result.runtimeMode,
            officialBaseline: .preserve,
            savedRelayProfiles: .preserve,
            existingProviderImportReport: .preserve,
            hasPendingSessionRecovery: committed
                ? .set(false)
                : .preserve,
            phase: phase,
            status: status,
            errorMessage: errorMessage,
            clearsRuntimeDrift: committed,
            refreshesRuntimeTruth: committed,
            refreshesCredentialBridge: false,
            refreshesSessionPreview: committed
        )
    }
}
