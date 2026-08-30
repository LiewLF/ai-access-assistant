// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct ConfigWorkspaceSessionTarget {
    let providerID: String
    let profileID: String
}

/// Owns durable session-continuity policy updates and derives the current
/// SessionSync target from authoritative control state.
@MainActor
struct ConfigWorkspaceSessionPolicyService {
    let stateStore: CodexStateStore
    let journalStore: SessionSyncJournalStore

    func setAuthorization(_ allowed: Bool) throws {
        var state = try stateStore.load()
        state.sessionSyncAuthorized = allowed
        try stateStore.save(state)
    }

    func pendingTransaction() throws ->
        SessionSyncTransaction? {
        try journalStore.pending().first
    }

    func hasPendingRecovery() throws -> Bool {
        try pendingTransaction() != nil
    }

    func currentTarget() throws ->
        ConfigWorkspaceSessionTarget {
        let state = try stateStore.load()
        switch state.currentMode {
        case .official:
            return ConfigWorkspaceSessionTarget(
                providerID: "openai",
                profileID: "official"
            )
        case .relay:
            guard let activeID = state.activeRelayID,
                  let profile = state.relayProfiles
                    .first(where: { $0.id == activeID })
            else {
                throw CodexControlError.externalDrift
            }
            return ConfigWorkspaceSessionTarget(
                providerID:
                    profile.providerID
                    ?? PreservingTOMLEditor
                        .providerIdentifier(profile.id),
                profileID: profile.id
            )
        case .external:
            throw CodexControlError.externalDrift
        }
    }
}
