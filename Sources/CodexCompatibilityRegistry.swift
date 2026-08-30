import Foundation

struct CodexCompatibilityRegistrySnapshot: Equatable {
    let appVersion: String
    let appBuild: String
    let allowsWrites: Bool
    let evidenceSummary: String
}

enum CodexCompatibilityRegistry {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var snapshots:
            [String: CodexCompatibilityRegistrySnapshot] = [:]
    }

    private static let storage = Storage()

    static func record(
        applicationURL: URL,
        appVersion: String,
        appBuild: String,
        allowsWrites: Bool,
        evidenceSummary: String
    ) {
        storage.lock.lock()
        storage.snapshots[
            applicationURL.standardizedFileURL.path
        ] = CodexCompatibilityRegistrySnapshot(
            appVersion: appVersion,
            appBuild: appBuild,
            allowsWrites: allowsWrites,
            evidenceSummary: evidenceSummary
        )
        storage.lock.unlock()
    }

    static func snapshot(
        applicationURL: URL
    ) -> CodexCompatibilityRegistrySnapshot? {
        storage.lock.lock()
        let snapshot = storage.snapshots[
            applicationURL.standardizedFileURL.path
        ]
        storage.lock.unlock()
        return snapshot
    }
}
