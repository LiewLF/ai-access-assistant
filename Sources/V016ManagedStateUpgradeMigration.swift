// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V016ManagedStateUpgradeMigrationReceipt:
    Equatable, Sendable {
    let sourceSchema: Int
    let targetSchema: Int
    let sourceSHA256: String
    let targetSHA256: String
    let recoveryPreimageRetained: Bool
}

enum V016ManagedStateUpgradeMigrationOutcome:
    Equatable, Sendable {
    case noState
    case alreadyCurrent(schemaVersion: Int, sha256: String)
    case migrated(V016ManagedStateUpgradeMigrationReceipt)
}

enum V016ManagedStateUpgradeMigrationError:
    Error, Equatable {
    case committedStateInvalid
    case rollbackFailed
}

/// Explicit internal recovery primitive. Product startup and passive refresh
/// must not invoke this type because migration can write managed state.
struct V016ManagedStateUpgradeMigrator {
    let store: V011ManagedStateStore
    let validateCommittedState: (V011ManagedState) throws -> Void

    init(
        store: V011ManagedStateStore,
        validateCommittedState: @escaping (
            V011ManagedState
        ) throws -> Void = { _ in }
    ) {
        self.store = store
        self.validateCommittedState = validateCommittedState
    }

    func migrateIfNeeded()
        throws -> V016ManagedStateUpgradeMigrationOutcome {
        let fileURL = store.fileURL
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return .noState
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let sourceData = try Data(contentsOf: fileURL)
        let sourceSHA256 = TOMLSemanticEngine.sha256(sourceData)
        let sourceState = try store.load()
        guard sourceState.schemaVersion
                < V011ManagedState.currentSchemaVersion else {
            return .alreadyCurrent(
                schemaVersion: sourceState.schemaVersion,
                sha256: sourceSHA256
            )
        }

        let targetData = try store.preparedData(for: sourceState)
        let targetSHA256 = TOMLSemanticEngine.sha256(targetData)
        guard targetSHA256 != sourceSHA256 else {
            throw V016ManagedStateUpgradeMigrationError
                .committedStateInvalid
        }
        do {
            try store.writePrepared(
                targetData,
                expectedCurrentHash: sourceSHA256
            )
            let committedData = try Data(contentsOf: fileURL)
            guard TOMLSemanticEngine.sha256(committedData)
                    == targetSHA256 else {
                throw V016ManagedStateUpgradeMigrationError
                    .committedStateInvalid
            }
            let committedState = try store.load()
            guard committedState.schemaVersion
                    == V011ManagedState.currentSchemaVersion else {
                throw V016ManagedStateUpgradeMigrationError
                    .committedStateInvalid
            }
            try validateCommittedState(committedState)
            return .migrated(
                V016ManagedStateUpgradeMigrationReceipt(
                    sourceSchema: sourceState.schemaVersion,
                    targetSchema:
                        V011ManagedState.currentSchemaVersion,
                    sourceSHA256: sourceSHA256,
                    targetSHA256: targetSHA256,
                    recoveryPreimageRetained: true
                )
            )
        } catch {
            do {
                try store.restoreOriginal(
                    sourceData,
                    originalHash: sourceSHA256,
                    intendedHash: targetSHA256
                )
            } catch {
                throw V016ManagedStateUpgradeMigrationError
                    .rollbackFailed
            }
            throw error
        }
    }
}
