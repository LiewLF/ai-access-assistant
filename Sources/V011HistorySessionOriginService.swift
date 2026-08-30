// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistorySessionOriginService: @unchecked Sendable {
    let dependencies: V011HistoryDependencies
    let ledgerRoot: URL

    func captureBeforeRepair() async throws {
        var sessions: [SessionCoreSession] = []
        var offset = 0
        while true {
            try Task.checkCancellation()
            let page = try await dependencies.sessionCore
                .list(
                    codexHome: dependencies.codexHome,
                    limit: 50,
                    offset: offset,
                    provider: nil
                )
            sessions.append(contentsOf: page.sessions)
            guard page.hasMore else { break }
            guard !page.sessions.isEmpty else { break }
            offset += page.sessions.count
        }
        let dependencies = dependencies
        let ledgerRoot = ledgerRoot
        try await Task.detached {
            let state = try V011ManagedStateStore(
                fileURL: dependencies.controlRoot
                    .appendingPathComponent(
                        "V011",
                        isDirectory: true
                    )
                    .appendingPathComponent("state.json")
            ).load()
            let known = Dictionary(
                uniqueKeysWithValues:
                    state.relayProfiles.map {
                        (
                            $0.v011ProviderID,
                            (id: $0.id, name: $0.name)
                        )
                    }
            )
            let store = V011SessionOriginLedgerStore(
                rootURL: ledgerRoot,
                keyProvider: dependencies.keyProvider
            )
            var payload = try store.load()
            payload = V011SessionOriginLedgerBuilder
                .merge(
                    sessions: sessions,
                    into: payload,
                    knownProfilesByProvider: known
                )
            if payload.initializedAt == nil {
                payload.initializedAt = Date()
            }
            try store.save(payload)
        }.value
    }

    func loadAndMerge(
        sessions: [SessionCoreSession]
    ) throws -> V011SessionOriginLedgerPayload {
        let store = V011SessionOriginLedgerStore(
            rootURL: ledgerRoot,
            keyProvider: dependencies.keyProvider
        )
        var ledger = try store.load()
        guard ledger.initializedAt != nil else {
            return ledger
        }
        let state = try V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent(
                    "V011",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "state.json"
                )
        ).load()
        let known = Dictionary(
            uniqueKeysWithValues:
                state.relayProfiles.map {
                    (
                        $0.v011ProviderID,
                        (
                            id: $0.id,
                            name: $0.name
                        )
                    )
                }
        )
        let merged = V011SessionOriginLedgerBuilder.merge(
            sessions: sessions,
            into: ledger,
            knownProfilesByProvider: known
        )
        if merged != ledger {
            try store.save(merged)
            ledger = merged
        }
        return ledger
    }
}
