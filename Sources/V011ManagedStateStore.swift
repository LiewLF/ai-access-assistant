// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011ManagedState: Codable, Equatable {
    static let currentSchemaVersion = 4

    var schemaVersion: Int
    var relayProfiles: [CodexRelayProfile]
    var managedProviderIDs: [String]
    var activeProfileID: String?
    var sessionSyncAuthorized: Bool
    var didMigrateFrom0103: Bool
    var lastSessionJournalPath: String?
    var lastSuccessfulSwitchID: String?
    var lastVerifiedConfigHash: String?
    var lastVerifiedProviderID: String?
    var lastVerifiedAt: Date?
    var officialBaseline: V011OfficialBaselineRecord?
    var officialRootOverlay:
        V011OfficialRootOverlayRecord?
    var activeCutoverConfiguration:
        FableCutoverConfigurationRecord?
    var lastKnownGoodCutoverConfiguration:
        FableCutoverConfigurationRecord?

    static let empty = V011ManagedState(
        schemaVersion: currentSchemaVersion,
        relayProfiles: [],
        managedProviderIDs: [],
        activeProfileID: nil,
        sessionSyncAuthorized: true,
        didMigrateFrom0103: false,
        lastSessionJournalPath: nil,
        lastSuccessfulSwitchID: nil,
        lastVerifiedConfigHash: nil,
        lastVerifiedProviderID: nil,
        lastVerifiedAt: nil,
        officialBaseline: nil,
        officialRootOverlay: nil,
        activeCutoverConfiguration: nil,
        lastKnownGoodCutoverConfiguration: nil
    )

    var managedProviderIDSet: Set<String> {
        Set(managedProviderIDs)
    }

    mutating func upsert(_ profile: CodexRelayProfile) {
        relayProfiles.removeAll {
            $0.id == profile.id
                || $0.v011ProviderID
                    == profile.v011ProviderID
        }
        relayProfiles.append(profile)
        relayProfiles.sort {
            $0.name.localizedStandardCompare($1.name)
                == .orderedAscending
        }
        if !managedProviderIDs.contains(
            profile.v011ProviderID
        ) {
            managedProviderIDs.append(
                profile.v011ProviderID
            )
            managedProviderIDs.sort()
        }
    }
}

struct V011ManagedStateStore {
    let fileURL: URL

    func load() throws -> V011ManagedState {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return .empty
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        let state = try JSONDecoder().decode(
            V011ManagedState.self,
            from: Data(contentsOf: fileURL)
        )
        guard state.schemaVersion >= 1,
              state.schemaVersion <= V011ManagedState.currentSchemaVersion else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if let record = state.officialRootOverlay,
           record.trustedOverlay(
                for: record.versionContractSchemaID
           ) == nil {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if let active = state.activeCutoverConfiguration,
           active.state != .active || !active.isSafeRecord {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if let lastKnownGood = state.lastKnownGoodCutoverConfiguration,
           lastKnownGood.state != .lastKnownGood
               || !lastKnownGood.isSafeRecord {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return state
    }

    func save(_ state: V011ManagedState) throws {
        _ = try save(
            state,
            expectedCurrentHash:
                SessionSyncFileSafety.hashIfPresent(fileURL)
        )
    }

    @discardableResult
    func save(
        _ state: V011ManagedState,
        expectedCurrentHash: String?
    ) throws -> String {
        let data = try preparedData(for: state)
        try writePrepared(
            data,
            expectedCurrentHash: expectedCurrentHash
        )
        return TOMLSemanticEngine.sha256(data)
    }

    func preparedData(
        for state: V011ManagedState
    ) throws -> Data {
        var copy = state
        copy.schemaVersion =
            V011ManagedState.currentSchemaVersion
        let encoder = JSONEncoder()
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        let encoded = try encoder.encode(copy)
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return encoded
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        return try preservingUnknownJSONFields(
            encoded,
            from: Data(contentsOf: fileURL),
            knownRootKeys: [
                "schemaVersion", "relayProfiles", "managedProviderIDs",
                "activeProfileID", "sessionSyncAuthorized",
                "didMigrateFrom0103", "lastSessionJournalPath",
                "lastSuccessfulSwitchID", "lastVerifiedConfigHash",
                "lastVerifiedProviderID", "lastVerifiedAt",
                "officialBaseline", "officialRootOverlay",
                "activeCutoverConfiguration",
                "lastKnownGoodCutoverConfiguration",
            ]
        )
    }

    func writePrepared(
        _ data: Data,
        expectedCurrentHash: String?
    ) throws {
        if let expectedCurrentHash {
            try SessionSyncFileSafety.requireRegularFile(fileURL)
            let current = try Data(contentsOf: fileURL)
            guard TOMLSemanticEngine.sha256(current)
                    == expectedCurrentHash else {
                throw V011SwitchError.concurrentConfigurationChange
            }
            try preserveRawRecordPreimage(current, for: fileURL)
        }
        try SessionSyncAtomicFile.write(
            data,
            to: fileURL,
            expectedHash: expectedCurrentHash,
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func restore(
        _ data: Data?,
        expectedCurrentHash: String?
    ) throws {
        if let data {
            if let expectedCurrentHash {
                try SessionSyncFileSafety.requireRegularFile(fileURL)
                let current = try Data(contentsOf: fileURL)
                guard TOMLSemanticEngine.sha256(current)
                        == expectedCurrentHash else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                try preserveRawRecordPreimage(current, for: fileURL)
            }
            try SessionSyncAtomicFile.write(
                data,
                to: fileURL,
                expectedHash: expectedCurrentHash,
                permissions: 0o600,
                modificationDate: nil
            )
            return
        }
        guard SessionSyncFileSafety.hashIfPresent(fileURL)
                == expectedCurrentHash else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
        try SessionSyncFileSafety.requireRegularFile(fileURL)
        try FileManager.default.removeItem(at: fileURL)
        try synchronizeParentDirectory()
    }

    func restoreOriginal(
        _ data: Data?,
        originalHash: String?,
        intendedHash: String
    ) throws {
        if classifyAtomicWrite(
            at: fileURL,
            originalHash: originalHash,
            intendedHash: intendedHash
        ) == .original {
            try verifyRestoredOriginal(
                originalHash: originalHash
            )
            return
        }
        do {
            try restore(
                data,
                expectedCurrentHash: intendedHash
            )
        } catch {
            guard classifyAtomicWrite(
                at: fileURL,
                originalHash: originalHash,
                intendedHash: intendedHash
            ) == .original else {
                throw error
            }
        }
        guard classifyAtomicWrite(
            at: fileURL,
            originalHash: originalHash,
            intendedHash: intendedHash
        ) == .original else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
        try verifyRestoredOriginal(
            originalHash: originalHash
        )
    }

    private func verifyRestoredOriginal(
        originalHash: String?
    ) throws {
        if let originalHash {
            var metadata = stat()
            guard lstat(fileURL.path, &metadata) == 0,
                  metadata.st_mode & S_IFMT == S_IFREG,
                  metadata.st_mode & 0o777 == 0o600,
                  SessionSyncFileSafety.hashIfPresent(fileURL)
                    == originalHash else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }
        } else {
            var metadata = stat()
            errno = 0
            guard lstat(fileURL.path, &metadata) != 0,
                  errno == ENOENT else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }
        }
        try synchronizeParentDirectory()
        guard SessionSyncFileSafety.hashIfPresent(fileURL)
                == originalHash else {
            throw V011SwitchError
                .concurrentConfigurationChange
        }
    }

    private func synchronizeParentDirectory() throws {
        let descriptor = Darwin.open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
    }
}

func preservingUnknownJSONFields(
    _ encoded: Data,
    from original: Data,
    knownRootKeys: Set<String>? = nil
) throws -> Data {
    let encodedObject = try JSONSerialization.jsonObject(
        with: encoded
    )
    let originalObject = try JSONSerialization.jsonObject(
        with: original
    )
    let merged: Any
    if let knownRootKeys,
       let encodedRoot = encodedObject as? [String: Any],
       let originalRoot = originalObject as? [String: Any] {
        var root = originalRoot.filter {
            !knownRootKeys.contains($0.key)
        }
        for (key, value) in encodedRoot {
            root[key] = value
        }
        merged = root
    } else {
        merged = mergeKnownJSONValue(
            encodedObject,
            preserving: originalObject
        )
    }
    return try JSONSerialization.data(
        withJSONObject: merged,
        options: [.prettyPrinted, .sortedKeys]
    )
}

/// Directory-fd anchored I/O for Build63 control-plane records. Every leaf is
/// relative to an already-opened canonical directory; symlinks are never
/// followed, and the directory entry identity is verified before and after
/// the operation.
