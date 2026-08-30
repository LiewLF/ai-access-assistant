// SPDX-License-Identifier: AGPL-3.0-only

import CoreFoundation
import CryptoKit
import Darwin
import Foundation

struct TrustedUpdateArtifactExpectation: Equatable, Sendable {
    let build: Int
    let byteCount: Int64
    let sha256: String
}

struct TrustedUpdateArtifactEvidence: Equatable, Sendable {
    let build: Int
    let filePath: String
    let byteCount: Int64
    let sha256: String
}

enum TrustedUpdateStagingError: Error, Equatable {
    case unsafeArtifact
    case artifactTooLarge
    case artifactSizeMismatch
    case artifactHashMismatch
    case invalidTransactionID
    case unsafeStatePath
    case invalidState
    case unsupportedStateSchema(Int)
    case futureAcceptedBuild
    case staleMigrationArtifact
    case concurrentStateChange
    case migrationVerificationFailed
}

extension TrustedUpdateStagingError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsafeArtifact:
            return "更新包路径或文件类型不安全"
        case .artifactTooLarge:
            return "更新包超过安全处理范围"
        case .artifactSizeMismatch:
            return "更新包大小与签名清单不一致"
        case .artifactHashMismatch:
            return "更新包哈希与签名清单不一致"
        case .invalidTransactionID:
            return "更新事务编号无效"
        case .unsafeStatePath:
            return "更新状态路径不安全"
        case .invalidState:
            return "更新状态格式无效"
        case .unsupportedStateSchema(let schema):
            return "更新状态版本不受支持：\(schema)"
        case .futureAcceptedBuild:
            return "更新状态记录了尚未安装的Build"
        case .staleMigrationArtifact:
            return "迁移路径已有未处理文件"
        case .concurrentStateChange:
            return "更新状态在迁移期间发生变化"
        case .migrationVerificationFailed:
            return "更新状态迁移后核对失败"
        }
    }
}

enum TrustedUpdateArtifactVerifier {
    static let maximumArtifactBytes: Int64 = 2_147_483_648

    static func verify(
        fileURL: URL,
        expectation: TrustedUpdateArtifactExpectation
    ) throws -> TrustedUpdateArtifactEvidence {
        let file = fileURL.standardizedFileURL
        guard file.isFileURL,
              file.path.hasPrefix("/"),
              file.pathExtension.lowercased() == "dmg",
              expectation.build > 0,
              expectation.byteCount > 0,
              expectation.byteCount <= maximumArtifactBytes,
              normalizedSHA256(expectation.sha256) != nil else {
            throw TrustedUpdateStagingError.unsafeArtifact
        }
        var metadata = stat()
        guard Darwin.lstat(file.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            throw TrustedUpdateStagingError.unsafeArtifact
        }
        let actualBytes = Int64(metadata.st_size)
        guard actualBytes <= maximumArtifactBytes else {
            throw TrustedUpdateStagingError.artifactTooLarge
        }
        guard actualBytes == expectation.byteCount else {
            throw TrustedUpdateStagingError.artifactSizeMismatch
        }
        let actualHash = try sha256File(file)
        guard actualHash == expectation.sha256.lowercased() else {
            throw TrustedUpdateStagingError.artifactHashMismatch
        }
        return TrustedUpdateArtifactEvidence(
            build: expectation.build,
            filePath: file.path,
            byteCount: actualBytes,
            sha256: actualHash
        )
    }

    private static func normalizedSHA256(_ value: String) -> String? {
        let normalized = value.lowercased()
        guard normalized.utf8.count == 64,
              normalized.range(
                of: #"^[0-9a-f]{64}$"#,
                options: .regularExpression
              ) != nil else {
            return nil
        }
        return normalized
    }

    private static func sha256File(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return Data(hasher.finalize()).trustedUpdateHexString
    }
}

struct TrustedUpdateStateMigrationReceipt: Equatable, Sendable {
    let transactionID: String
    let sourceSchema: Int
    let targetSchema: Int
    let sourceSHA256: String
    let targetSHA256: String
    let backupPath: String
    let backupRetained: Bool
}

enum TrustedUpdateStateMigrationOutcome: Equatable, Sendable {
    case alreadyCurrent(schemaVersion: Int, sha256: String)
    case migrated(TrustedUpdateStateMigrationReceipt)
}

struct TrustedUpdateStateMigrator {
    static let currentSchemaVersion = 2
    static let maximumStateBytes = 1_048_576

    let fileManager = FileManager.default

    func migrateIfNeeded(
        stateURL: URL,
        transactionID: String,
        installedBuild: Int
    ) throws -> TrustedUpdateStateMigrationOutcome {
        guard safeTransactionID(transactionID) else {
            throw TrustedUpdateStagingError.invalidTransactionID
        }
        guard installedBuild > 0 else {
            throw TrustedUpdateStagingError.invalidState
        }
        let state = try requireSafeStateFile(stateURL)
        let sourceData = try boundedData(state)
        let sourceHash = sha256(sourceData)
        let sourceObject = try object(sourceData)
        let sourceSchema = try integer(
            sourceObject["schemaVersion"]
        ) ?? 0
        if sourceSchema > Self.currentSchemaVersion {
            throw TrustedUpdateStagingError.unsupportedStateSchema(
                sourceSchema
            )
        }
        if sourceSchema == Self.currentSchemaVersion {
            try validateCurrentState(
                sourceObject,
                installedBuild: installedBuild
            )
            return .alreadyCurrent(
                schemaVersion: sourceSchema,
                sha256: sourceHash
            )
        }
        guard sourceSchema == 1 else {
            throw TrustedUpdateStagingError.unsupportedStateSchema(
                sourceSchema
            )
        }

        let migratedObject = try migrateV1(
            sourceObject,
            installedBuild: installedBuild
        )
        let targetData = try JSONSerialization.data(
            withJSONObject: migratedObject,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        guard targetData.count <= Self.maximumStateBytes else {
            throw TrustedUpdateStagingError.invalidState
        }
        let targetObject = try object(targetData)
        try validateCurrentState(
            targetObject,
            installedBuild: installedBuild
        )
        let targetHash = sha256(targetData)

        let parent = state.deletingLastPathComponent()
        let stem = state.deletingPathExtension().lastPathComponent
        let candidate = parent.appendingPathComponent(
            ".\(stem)-migration-\(transactionID).json"
        )
        let backup = parent.appendingPathComponent(
            ".\(stem)-preupdate-\(transactionID).json"
        )
        guard !fileManager.fileExists(atPath: candidate.path),
              !fileManager.fileExists(atPath: backup.path) else {
            throw TrustedUpdateStagingError.staleMigrationArtifact
        }

        var candidateCreated = false
        do {
            try targetData.write(to: candidate, options: .atomic)
            candidateCreated = true
            try secureFile(candidate)
            let candidateData = try boundedData(candidate)
            guard sha256(candidateData) == targetHash else {
                throw TrustedUpdateStagingError.migrationVerificationFailed
            }
            let currentData = try boundedData(state)
            guard sha256(currentData) == sourceHash else {
                throw TrustedUpdateStagingError.concurrentStateChange
            }
            try fileManager.copyItem(at: state, to: backup)
            try secureFile(backup)
            guard sha256(try boundedData(backup)) == sourceHash else {
                throw TrustedUpdateStagingError.migrationVerificationFailed
            }
            try fileManager.removeItem(at: candidate)
            candidateCreated = false
            do {
                try targetData.write(to: state, options: .atomic)
                try secureFile(state)
                let committed = try boundedData(state)
                let committedObject = try object(committed)
                try validateCurrentState(
                    committedObject,
                    installedBuild: installedBuild
                )
                guard sha256(committed) == targetHash else {
                    throw TrustedUpdateStagingError.migrationVerificationFailed
                }
            } catch {
                try? sourceData.write(to: state, options: .atomic)
                try? secureFile(state)
                throw error
            }
            return .migrated(
                TrustedUpdateStateMigrationReceipt(
                    transactionID: transactionID,
                    sourceSchema: sourceSchema,
                    targetSchema: Self.currentSchemaVersion,
                    sourceSHA256: sourceHash,
                    targetSHA256: targetHash,
                    backupPath: backup.path,
                    backupRetained: true
                )
            )
        } catch {
            if candidateCreated {
                try? fileManager.removeItem(at: candidate)
            }
            throw error
        }
    }

    private func migrateV1(
        _ source: [String: Any],
        installedBuild: Int
    ) throws -> [String: Any] {
        guard let acceptedBuild = try integer(source["acceptedBuild"]),
              acceptedBuild > 0 else {
            throw TrustedUpdateStagingError.invalidState
        }
        guard acceptedBuild <= installedBuild else {
            throw TrustedUpdateStagingError.futureAcceptedBuild
        }
        var target = source
        target.removeValue(forKey: "acceptedBuild")
        target["schemaVersion"] = Self.currentSchemaVersion
        target["lastAcceptedBuild"] = acceptedBuild
        target["lastKnownGoodBuild"] = acceptedBuild
        target["channel"] = "stable"
        target["automaticCheckEnabled"] = false
        return target
    }

    private func validateCurrentState(
        _ value: [String: Any],
        installedBuild: Int
    ) throws {
        guard try integer(value["schemaVersion"])
                == Self.currentSchemaVersion,
              let accepted = try integer(value["lastAcceptedBuild"]),
              let knownGood = try integer(value["lastKnownGoodBuild"]),
              accepted > 0,
              knownGood > 0,
              accepted <= installedBuild,
              knownGood <= accepted,
              value["channel"] as? String == "stable",
              value["automaticCheckEnabled"] as? Bool == false else {
            throw TrustedUpdateStagingError.invalidState
        }
    }

    private func requireSafeStateFile(_ value: URL) throws -> URL {
        let state = value.standardizedFileURL
        guard state.isFileURL,
              state.path.hasPrefix("/"),
              state.pathExtension.lowercased() == "json" else {
            throw TrustedUpdateStagingError.unsafeStatePath
        }
        var stateMetadata = stat()
        var parentMetadata = stat()
        guard Darwin.lstat(state.path, &stateMetadata) == 0,
              stateMetadata.st_mode & S_IFMT == S_IFREG,
              stateMetadata.st_uid == getuid(),
              Darwin.lstat(
                state.deletingLastPathComponent().path,
                &parentMetadata
              ) == 0,
              parentMetadata.st_mode & S_IFMT == S_IFDIR,
              parentMetadata.st_uid == getuid() else {
            throw TrustedUpdateStagingError.unsafeStatePath
        }
        return state
    }

    private func boundedData(_ url: URL) throws -> Data {
        let attributes = try fileManager.attributesOfItem(
            atPath: url.path
        )
        guard let size = attributes[.size] as? NSNumber,
              size.intValue > 0,
              size.intValue <= Self.maximumStateBytes else {
            throw TrustedUpdateStagingError.invalidState
        }
        return try Data(contentsOf: url)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        guard let value = try JSONSerialization.jsonObject(
            with: data,
            options: []
        ) as? [String: Any] else {
            throw TrustedUpdateStagingError.invalidState
        }
        return value
    }

    private func integer(_ value: Any?) throws -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let raw = number.int64Value
        guard raw >= Int64(Int.min),
              raw <= Int64(Int.max),
              NSNumber(value: raw) == number else {
            throw TrustedUpdateStagingError.invalidState
        }
        return Int(raw)
    }

    private func secureFile(_ url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    private func safeTransactionID(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57)
                || (byte >= 65 && byte <= 90)
                || (byte >= 97 && byte <= 122)
                || byte == 45 || byte == 46 || byte == 95
        }
    }

    private func sha256(_ data: Data) -> String {
        Data(SHA256.hash(data: data)).trustedUpdateHexString
    }
}

enum TrustedUpdateNetworkState: Equatable, Sendable {
    case online
    case offline
}

enum TrustedUpdateContinueReason: Equatable, Sendable {
    case noVerifiedUpdate
    case offlineNoVerifiedUpdate
    case offlineArtifactUnavailable
    case alreadyCurrent
}

enum TrustedUpdateStagingBlocker: Equatable, Sendable {
    case downgradeBuild
    case artifactDoesNotMatchOffer
    case migrationUnavailable
}

struct TrustedUpdateInstallConfirmation: Equatable, Sendable {
    let offer: TrustedUpdateOffer
    let artifact: TrustedUpdateArtifactEvidence
    let preparedOffline: Bool
    let requiresExplicitInstallConfirmation: Bool
    let writesBeforeConfirmation: Bool
    let automaticInstallAllowed: Bool
    let automaticRelaunchAllowed: Bool
}

enum TrustedUpdateStagingOutcome: Equatable, Sendable {
    case continueCurrent(TrustedUpdateContinueReason)
    case requiresExplicitDownload(TrustedUpdateOffer)
    case readyForUserConfirmation(TrustedUpdateInstallConfirmation)
    case blocked(TrustedUpdateStagingBlocker)
}

enum TrustedUpdateInstallPlanner {
    static func plan(
        installedBuild: Int,
        offer: TrustedUpdateOffer?,
        artifact: TrustedUpdateArtifactEvidence?,
        networkState: TrustedUpdateNetworkState,
        migrationReady: Bool
    ) -> TrustedUpdateStagingOutcome {
        guard let offer else {
            return .continueCurrent(
                networkState == .offline
                    ? .offlineNoVerifiedUpdate
                    : .noVerifiedUpdate
            )
        }
        if offer.build < installedBuild {
            return .blocked(.downgradeBuild)
        }
        if offer.build == installedBuild {
            return .continueCurrent(.alreadyCurrent)
        }
        guard let artifact else {
            return networkState == .offline
                ? .continueCurrent(.offlineArtifactUnavailable)
                : .requiresExplicitDownload(offer)
        }
        guard artifact.build == offer.build,
              artifact.byteCount == offer.byteCount,
              artifact.sha256 == offer.sha256.lowercased() else {
            return .blocked(.artifactDoesNotMatchOffer)
        }
        guard migrationReady else {
            return .blocked(.migrationUnavailable)
        }
        return .readyForUserConfirmation(
            TrustedUpdateInstallConfirmation(
                offer: offer,
                artifact: artifact,
                preparedOffline: networkState == .offline,
                requiresExplicitInstallConfirmation: true,
                writesBeforeConfirmation: false,
                automaticInstallAllowed: false,
                automaticRelaunchAllowed: false
            )
        )
    }
}

private extension Data {
    var trustedUpdateHexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
