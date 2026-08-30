// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceRuntimeMonitorSnapshot {
    let state: CodexStateStore.State
    let truth: RuntimeTruth
    let driftReport: RuntimeDriftReport?
    let acceptsManagedState: Bool

    @MainActor
    func status(
        recordedRuntimeMode: CodexRuntimeMode,
        activeRelayIsUnverified: Bool,
        allowsManagedWrite: Bool,
        doctorBlockingReasons: [String]
    ) -> String {
        if truth.runtimeMode != recordedRuntimeMode {
            return
                "真实运行：\(truth.runtimeMode.rawValue)；助手记录：\(recordedRuntimeMode.rawValue)。状态不一致，禁止切换。"
        }
        if activeRelayIsUnverified {
            return
                "真实中转对应升级前的未验证旧档；必须先只读重新接管当前Provider"
        }
        if allowsManagedWrite {
            return ConfigWorkspaceRuntimeTruthService
                .verifiedStatus(truth)
        }
        return (
            truth.blockingReasons
                + doctorBlockingReasons
        ).joined(separator: "；")
    }
}

enum ConfigWorkspaceRuntimeMonitorOutcome {
    case observed(ConfigWorkspaceRuntimeMonitorSnapshot)
    case failed(
        state: CodexStateStore.State?,
        message: String
    )
}

/// Owns durable state reads and the previous runtime observation used for
/// drift comparison. Published state remains in ConfigWorkspaceModel.
@MainActor
final class ConfigWorkspaceRuntimeMonitorController {
    private let stateStore: CodexStateStore
    private let truthService:
        ConfigWorkspaceRuntimeTruthService
    private var previousObservation:
        RuntimeTruthObservation?

    init(
        stateStore: CodexStateStore,
        truthService:
            ConfigWorkspaceRuntimeTruthService
    ) {
        self.stateStore = stateStore
        self.truthService = truthService
    }

    func refresh() ->
        ConfigWorkspaceRuntimeMonitorOutcome {
        observe(comparesWithPrevious: false)
    }

    func monitor() ->
        ConfigWorkspaceRuntimeMonitorOutcome {
        observe(comparesWithPrevious: true)
    }

    private func observe(
        comparesWithPrevious: Bool
    ) -> ConfigWorkspaceRuntimeMonitorOutcome {
        let state: CodexStateStore.State
        do {
            state = try stateStore.load()
        } catch {
            return .failed(
                state: nil,
                message: error.localizedDescription
            )
        }

        let truth: RuntimeTruth
        do {
            truth = try truthService.inspect()
        } catch {
            return .failed(
                state: state,
                message: error.localizedDescription
            )
        }

        let current = RuntimeTruthObservation(truth)
        let report = comparesWithPrevious
            ? previousObservation.flatMap {
                RuntimeDriftDetector.compare(
                    previous: $0,
                    current: current
                )
            }
            : nil
        previousObservation = current
        return .observed(
            ConfigWorkspaceRuntimeMonitorSnapshot(
                state: state,
                truth: truth,
                driftReport: report,
                acceptsManagedState:
                    ManagedRuntimeReconciliationPolicy
                        .accepts(
                            runtimeMode: truth.runtimeMode,
                            fileHash:
                                truth.persistent.fileHash,
                            state: state
                        )
            )
        )
    }
}
