// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConfigWorkspaceManagementExitResult {
    case exited
    case blocked(message: String)
    case failed(message: String)
}

/// Owns destructive managed-data cleanup after ConfigWorkspaceModel proves
/// official runtime and explicit recovery-test confirmation.
struct ConfigWorkspaceManagementExitService {
    let adapter: CodexConfigurationAdapter
    let controlRoot: URL

    func execute(
        relayProfiles: [CodexRelayProfile]
    ) -> ConfigWorkspaceManagementExitResult {
        do {
            let configText = String(
                decoding:
                    try adapter.currentConfigData() ?? Data(),
                as: UTF8.self
            )
            guard !configText.contains(
                PersistentCredentialBridge.helperName
            ) else {
                return .blocked(
                    message:
                        "config.toml仍引用中转凭据Helper，不能退出托管"
                )
            }
            for profile in relayProfiles {
                try RelaySecretStore.delete(
                    relayID: profile.id
                )
            }
            try AppVaultKeyStore.delete()
            if FileManager.default.fileExists(
                atPath: controlRoot.path
            ) {
                try FileManager.default.removeItem(
                    at: controlRoot
                )
            }
            return .exited
        } catch {
            return .failed(
                message: error.localizedDescription
            )
        }
    }
}
