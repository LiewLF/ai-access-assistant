import Foundation

@MainActor
final class V011WorkspaceCollaborator {
    let codexHomeURL: URL
    let controlRoot: URL
    let stateStore: CodexStateStore
    let keyProvider: () throws -> Data
    var runtimeTask: Task<Void, Never>?
    var sessionListTask: Task<Void, Never>?

    init(dependencies: ConfigWorkspaceDependencies) {
        if let override = dependencies.codexHomeURL {
            codexHomeURL = override.standardizedFileURL
        } else if let override = ProcessInfo.processInfo
            .environment["CODEX_HOME"], !override.isEmpty {
            codexHomeURL = URL(
                fileURLWithPath: override,
                isDirectory: true
            ).standardizedFileURL
        } else {
            codexHomeURL = FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(
                    ".codex",
                    isDirectory: true
                )
        }

        if let override = dependencies.controlRootURL {
            controlRoot = override.standardizedFileURL
        } else {
            let base = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? FileManager.default
                .homeDirectoryForCurrentUser
                .appendingPathComponent(
                    "Library/Application Support"
                )
            controlRoot = base.appendingPathComponent(
                "AI接入助手/ControlPlane",
                isDirectory: true
            )
        }

        stateStore = CodexStateStore(
            fileURL: controlRoot.appendingPathComponent(
                "state.json"
            )
        )
        keyProvider = dependencies.vaultKeyProvider
    }
}
