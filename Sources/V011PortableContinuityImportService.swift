import Foundation

struct V011PortableContinuityRecoveryState: Sendable {
    let hasPendingImport: Bool
    let errorMessage: String?
}

struct V011PortableContinuityReloadSnapshot: @unchecked Sendable {
    let managedState: V011ManagedState?
    let recovery: V011PortableContinuityRecoveryState
}

enum V011PortableContinuityApplyOutcome: @unchecked Sendable {
    case success(
        PortableContinuityApplyResult,
        V011PortableContinuityReloadSnapshot
    )
    case failure(
        Error,
        V011PortableContinuityReloadSnapshot
    )
}

enum V011PortableContinuityRecoveryOutcome: @unchecked Sendable {
    case success(Int, V011PortableContinuityReloadSnapshot)
    case failure(Error, V011PortableContinuityReloadSnapshot)
}

/// Owns portable-continuity file I/O, transaction execution, and durable
/// state reload. MainActor controller owns busy/status ordering; its façade
/// delegate applies returned state.
struct V011PortableContinuityImportService: @unchecked Sendable {
    private let dependencies: V011AccessDependencies

    init(dependencies: V011AccessDependencies) {
        self.dependencies = dependencies
    }

    func prepare(
        sourceURL: URL,
        protectedProviderID: String?
    ) async throws -> PortableContinuityImportSession {
        let service = self
        return try await Task.detached(priority: .userInitiated) {
            try service.coordinator.prepare(
                sourceURL: sourceURL,
                targetVersion: AppReleaseMetadata.version,
                targetBuild: AppReleaseMetadata.build,
                targetPlatform: .macOS,
                protectedProviderID: protectedProviderID
            )
        }.value
    }

    func apply(
        _ request: PortableContinuityApplyRequest
    ) async -> V011PortableContinuityApplyOutcome {
        let service = self
        return await Task.detached(priority: .userInitiated) {
            service.performApply(request)
        }.value
    }

    func recoverPending()
        async -> V011PortableContinuityRecoveryOutcome {
        let service = self
        return await Task.detached(priority: .userInitiated) {
            service.performRecovery()
        }.value
    }

    func recoveryState() -> V011PortableContinuityRecoveryState {
        do {
            return V011PortableContinuityRecoveryState(
                hasPendingImport:
                    try !coordinator.journalStore.pending().isEmpty,
                errorMessage: nil
            )
        } catch {
            return V011PortableContinuityRecoveryState(
                hasPendingImport: true,
                errorMessage: "迁移导入恢复记录无法安全读取"
            )
        }
    }

    private func performApply(
        _ request: PortableContinuityApplyRequest
    ) -> V011PortableContinuityApplyOutcome {
        do {
            let result = try coordinator.apply(request)
            return .success(
                result,
                try successfulReloadSnapshot()
            )
        } catch {
            return .failure(error, fallbackReloadSnapshot())
        }
    }

    private func performRecovery()
        -> V011PortableContinuityRecoveryOutcome {
        do {
            let count = try coordinator.recoverPending()
            return .success(
                count,
                try successfulReloadSnapshot()
            )
        } catch {
            return .failure(error, fallbackReloadSnapshot())
        }
    }

    private func successfulReloadSnapshot() throws
        -> V011PortableContinuityReloadSnapshot {
        V011PortableContinuityReloadSnapshot(
            managedState: try stateStore.load(),
            recovery: recoveryState()
        )
    }

    private func fallbackReloadSnapshot()
        -> V011PortableContinuityReloadSnapshot {
        V011PortableContinuityReloadSnapshot(
            managedState: try? stateStore.load(),
            recovery: recoveryState()
        )
    }

    private var coordinator: PortableContinuityImportCoordinator {
        PortableContinuityImportCoordinator(
            controlRoot: dependencies.controlRoot,
            credentialStore: dependencies.credentialStore,
            keyProvider: dependencies.keyProvider
        )
    }

    private var stateStore: V011ManagedStateStore {
        V011ManagedStateStore(
            fileURL: dependencies.controlRoot
                .appendingPathComponent("V011", isDirectory: true)
                .appendingPathComponent("state.json")
        )
    }
}
