// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceSimulationRequest {
    let providerName: String
    let baseURL: String
    let modelName: String
    let relayID: String
    let agent: DesktopAgent
}

enum ConfigWorkspaceSimulationOutcome {
    case profilesCreated(
        [ManagedConfigurationProfile],
        activeProfileID: String,
        status: String
    )
    case switched(
        activeProfileID: String,
        status: String
    )
    case failed(status: String)
}

@MainActor
protocol ConfigWorkspaceSimulationControllerDelegate:
    AnyObject {
    func configWorkspaceSimulationDidFinish(
        _ outcome: ConfigWorkspaceSimulationOutcome
    )
}

/// Owns simulation-only vault artifacts and in-memory profile switching. No
/// live Codex config/auth path is read or written by this controller.
@MainActor
final class ConfigWorkspaceSimulationController {
    private weak var delegate:
        (any ConfigWorkspaceSimulationControllerDelegate)?
    private var engine = SimulatedSwitchEngine(
        activeProfileID: "official"
    )

    init(
        delegate:
            any ConfigWorkspaceSimulationControllerDelegate
    ) {
        self.delegate = delegate
    }

    func createProfiles(
        _ request: ConfigWorkspaceSimulationRequest
    ) {
        do {
            let manager = FileManager.default
            let applicationSupport = manager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
                ?? manager.homeDirectoryForCurrentUser
                    .appendingPathComponent(
                        "Library/Application Support"
                    )
            let vault = SecureProfileVault(
                rootURL: applicationSupport
                    .appendingPathComponent(
                        "AI接入助手/ProfileVault",
                        isDirectory: true
                    )
            )
            let officialManifest = try vault.saveSnapshot(
                profileID: "official",
                adapterVersion: "0.6.0-simulation",
                inputs: [
                    SnapshotInput(
                        relativePath:
                            "simulation/official.json",
                        data: Data(
                            "{\"mode\":\"official\",\"simulation\":true}"
                                .utf8
                        ),
                        permissions: 0o600
                    ),
                ]
            )
            let relaySummary =
                """
                {"mode":"relay","simulation":true,"provider":"\(request.providerName)","baseURL":"\(request.baseURL)","model":"\(request.modelName)"}
                """
            let relayManifest = try vault.saveSnapshot(
                profileID: request.relayID,
                adapterVersion: "0.6.0-simulation",
                inputs: [
                    SnapshotInput(
                        relativePath:
                            "simulation/relay.json",
                        data: Data(relaySummary.utf8),
                        permissions: 0o600
                    ),
                ]
            )
            let now = Date()
            let profiles = [
                ManagedConfigurationProfile(
                    id: "official",
                    name: "官方模式",
                    kind: .official,
                    agent: .codexDesktop,
                    relayID: nil,
                    createdAt: now,
                    lastVerifiedAt: now,
                    snapshotID: officialManifest.id
                ),
                ManagedConfigurationProfile(
                    id: request.relayID,
                    name: request.providerName.isEmpty
                        ? "中转模式"
                        : request.providerName,
                    kind: .relay,
                    agent: request.agent,
                    relayID: request.relayID,
                    createdAt: now,
                    lastVerifiedAt: nil,
                    snapshotID: relayManifest.id
                ),
            ]
            engine = SimulatedSwitchEngine(
                activeProfileID: "official"
            )
            delegate?.configWorkspaceSimulationDidFinish(
                .profilesCreated(
                    profiles,
                    activeProfileID: "official",
                    status:
                        "模拟配置档已加密保存；没有读取真实 config.toml/auth.json"
                )
            )
        } catch {
            delegate?.configWorkspaceSimulationDidFinish(
                .failed(
                    status:
                        "模拟配置档建立失败："
                        + error.localizedDescription
                )
            )
        }
    }

    func switchProfile(
        to profileID: String,
        compatibility: CompatibilityRecord
    ) {
        let status: String
        do {
            status = try engine.switchProfile(
                to: profileID,
                compatibility: compatibility
            ).message
        } catch {
            status = error.localizedDescription
        }
        delegate?.configWorkspaceSimulationDidFinish(
            .switched(
                activeProfileID: engine.activeProfileID,
                status: status
            )
        )
    }
}
