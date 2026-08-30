// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum ConfigWorkspaceKnownRelayReconciliationOutcome {
    case reconciled(CodexStateStore.State)
    case unmatched
    case failed(message: String)
}

/// Reconciles an externally observed relay config only when it uniquely
/// matches one durable profile, then returns the authoritative saved state.
@MainActor
struct ConfigWorkspaceKnownRelayReconciliationService {
    let adapter: CodexConfigurationAdapter
    let stateStore: CodexStateStore
    let engine: CodexSwitchEngine

    func reconcile() ->
        ConfigWorkspaceKnownRelayReconciliationOutcome {
        do {
            let state = try stateStore.load()
            let matches = try state.relayProfiles.filter {
                try adapter.manualConfigurationMatches($0)
            }
            guard matches.count == 1,
                  let profile = matches.first else {
                return .unmatched
            }
            _ = try engine.reconcileKnownRelay(
                profileID: profile.id
            )
            return .reconciled(try stateStore.load())
        } catch {
            return .failed(
                message: error.localizedDescription
            )
        }
    }
}
