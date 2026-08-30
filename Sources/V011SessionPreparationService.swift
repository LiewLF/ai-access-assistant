// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011SessionPreparationService {
    let codexHome: URL
    let sessionRecoveryRoot: URL
    let sessionCore: any V011SessionCoreOperating
    let originLedgerStore: V011SessionOriginLedgerStore
    let knownProfilesByProvider:
        [String: (id: String, name: String)]

    func prepareRecoveryRoot() throws {
        let manager = FileManager.default
        if manager.fileExists(
            atPath: sessionRecoveryRoot.path
        ) {
            let values = try sessionRecoveryRoot
                .resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isSymbolicLinkKey,
                    ]
                )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw V011SwitchError
                    .invalidRecoveryJournal
            }
        } else {
            try manager.createDirectory(
                at: sessionRecoveryRoot,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionRecoveryRoot.path
        )
    }

    func captureOrigins(
        managedState: V011ManagedState
    ) async throws {
        var payload = try originLedgerStore.load()
        var offset = 0
        var captured: [SessionCoreSession] = []
        while true {
            let page = try await sessionCore.list(
                codexHome: codexHome,
                limit: 50,
                offset: offset,
                provider: nil
            )
            captured.append(contentsOf: page.sessions)
            guard page.hasMore else { break }
            offset += page.sessions.count
            guard !page.sessions.isEmpty else { break }
        }
        var known = knownProfilesByProvider
        for profile in managedState.relayProfiles {
            known[profile.v011ProviderID] = (
                profile.id,
                profile.name
            )
        }
        payload = V011SessionOriginLedgerBuilder.merge(
            sessions: captured,
            into: payload,
            knownProfilesByProvider: known
        )
        if payload.initializedAt == nil {
            payload.initializedAt = Date()
        }
        try originLedgerStore.save(payload)
    }

    func markOriginsVisible(
        providerID: String
    ) throws {
        _ = providerID
        // 可见Provider由Codex SQLite和rollout保存；来源账本只保存
        // 首次来源，不能把“当前可见标签”误写成“创建来源”。
    }
}
