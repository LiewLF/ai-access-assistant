// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistoryDependencies: @unchecked Sendable {
    let codexHome: URL
    let controlRoot: URL
    let sessionCore: any V011HistorySessionCoreOperating
    let keyProvider: @Sendable () throws -> Data
    let stopConfigurationWriters: @Sendable () throws -> Void
    let relaunchCodex: @Sendable () throws -> Void

    static let live: V011HistoryDependencies = {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support",
                    isDirectory: true
                )
        let codexHome: URL
        if let override = ProcessInfo.processInfo
            .environment["CODEX_HOME"],
           !override.isEmpty {
            codexHome = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        } else {
            codexHome = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".codex",
                    isDirectory: true
                )
        }
        return V011HistoryDependencies(
            codexHome: codexHome,
            controlRoot: support
                .appendingPathComponent(
                    "AI接入助手",
                    isDirectory: true
                )
                .appendingPathComponent(
                    "ControlPlane",
                    isDirectory: true
                ),
            sessionCore: SessionCoreClient(),
            keyProvider: {
                try AppVaultKeyStore.loadOrCreate()
            },
            stopConfigurationWriters: {
                try FableMacOSProcessController()
                    .stopConfigurationWriters()
            },
            relaunchCodex: {
                try FableMacOSProcessController()
                    .relaunchCodex()
            }
        )
    }()
}
