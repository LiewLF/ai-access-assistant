// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011Migration0103Error: LocalizedError, Equatable {
    case unsafeSourceFile(String)
    case unsupportedManifestSchema(Int)
    case pathFingerprintMismatch
    case archiveVerificationFailed
    case sourceChangedDuringPreparation
    case invalidAdoptedProfileID
    case completedWithDifferentProfile

    var errorDescription: String? {
        switch self {
        case let .unsafeSourceFile(path):
            return "0.10.3迁移源不是安全的普通文件：\(path)"
        case let .unsupportedManifestSchema(version):
            return "0.10.3迁移清单Schema版本\(version)高于当前支持版本"
        case .pathFingerprintMismatch:
            return "现有0.10.3迁移档案不属于当前控制目录或CODEX_HOME"
        case .archiveVerificationFailed:
            return "0.10.3加密迁移档案校验失败"
        case .sourceChangedDuringPreparation:
            return "0.10.3状态或Codex配置在归档时发生变化，未生成迁移清单"
        case .invalidAdoptedProfileID:
            return "接管配置档ID无效，迁移档案未提交"
        case .completedWithDifferentProfile:
            return "0.10.3迁移档案已由另一个配置档完成接管"
        }
    }
}

struct V011Migration0103FileSummary: Codable, Equatable {
    let role: String
    let existed: Bool
    let sha256: String?
    let byteCount: Int
    let permissions: Int?
}

struct V011Migration0103RelaySummary: Codable, Equatable {
    let id: String
    let providerID: String?
    let name: String
    let baseURLHash: String
    let wireProtocol: String
    let defaultModel: String
    let modelCount: Int
}

struct V011Migration0103BaselineSummary: Codable, Equatable {
    let trust: String
    let snapshotID: String
    let snapshotProfileID: String
    let adapterVersion: String
    let codexHomePathHash: String
    let configExisted: Bool
    let authExisted: Bool
    let configHash: String?
    let authHash: String?
    let createdAt: Date
}

struct V011Migration0103Manifest: Codable, Equatable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let archiveID: String
    let sourceVersion: String
    let targetVersion: String
    let sourceControlPlanePathHash: String
    let targetCodexHomePathHash: String
    let snapshot: SnapshotManifest
    let legacyStateFile: V011Migration0103FileSummary
    let codexConfigFile: V011Migration0103FileSummary
    let legacyStateSchemaVersion: Int?
    let legacyCurrentMode: String?
    let legacyActiveRelayID: String?
    let legacyRelays: [V011Migration0103RelaySummary]
    let legacyBaseline: V011Migration0103BaselineSummary?
    let credentialBridgeProfileIDs: [String]
    let legacyStateHadLastTransaction: Bool
    let legacyTransactionArtifactsPresent: Bool
    let legacySnapshotArtifactsPresent: Bool
    let legacyArtifactsPreservedInPlace: Bool
    let preparedAt: Date
    var completedAt: Date?
    var adoptedProfileID: String?
}

struct V011MigrationCoordinator {
    static let legacyStateRelativePath =
        "legacy-control-plane/state.json"
    static let codexConfigRelativePath =
        "target-codex-home/config.toml"

    let controlRootURL: URL
    let codexHomeURL: URL
    let keyProvider: () throws -> Data
    let now: () -> Date

    init(
        controlRootURL: URL,
        codexHomeURL: URL,
        keyProvider: @escaping () throws -> Data =
            AppVaultKeyStore.loadOrCreate,
        now: @escaping () -> Date = Date.init
    ) {
        self.controlRootURL =
            controlRootURL.standardizedFileURL
        self.codexHomeURL = codexHomeURL.standardizedFileURL
        self.keyProvider = keyProvider
        self.now = now
    }

    var manifestURL: URL {
        controlRootURL
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent(
                "Migration0103",
                isDirectory: true
            )
            .appendingPathComponent("manifest.json")
    }

    var vaultRootURL: URL {
        controlRootURL
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent(
                "Migration0103Vault",
                isDirectory: true
            )
    }

    var legacyStateURL: URL {
        controlRootURL.appendingPathComponent("state.json")
    }

    var codexConfigURL: URL {
        codexHomeURL.appendingPathComponent("config.toml")
    }

    func loadManifest() throws -> V011Migration0103Manifest? {
        guard FileManager.default.fileExists(
            atPath: manifestURL.path
        ) else {
            return nil
        }
        try requireRegularFile(manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest = try decoder.decode(
            V011Migration0103Manifest.self,
            from: Data(contentsOf: manifestURL)
        )
        guard manifest.schemaVersion
                <= V011Migration0103Manifest
                    .currentSchemaVersion else {
            throw V011Migration0103Error
                .unsupportedManifestSchema(
                    manifest.schemaVersion
                )
        }
        try verifyPathFingerprints(manifest)
        return manifest
    }

    @discardableResult
    func prepareIfNeeded() throws
        -> V011Migration0103Manifest {
        if let existing = try loadManifest() {
            try verifyArchive(existing)
            return existing
        }

        let legacyStateInput = try snapshotInput(
            at: legacyStateURL,
            relativePath: Self.legacyStateRelativePath
        )
        let configInput = try snapshotInput(
            at: codexConfigURL,
            relativePath: Self.codexConfigRelativePath
        )
        let legacyState = legacyStateInput == nil
            ? nil
            : try CodexStateStore(
                fileURL: legacyStateURL
            ).load()
        let verifiedLegacyStateInput = try snapshotInput(
            at: legacyStateURL,
            relativePath: Self.legacyStateRelativePath
        )
        let verifiedConfigInput = try snapshotInput(
            at: codexConfigURL,
            relativePath: Self.codexConfigRelativePath
        )
        guard sameSnapshotInput(
                legacyStateInput,
                verifiedLegacyStateInput
              ),
              sameSnapshotInput(configInput, verifiedConfigInput) else {
            throw V011Migration0103Error
                .sourceChangedDuringPreparation
        }
        let legacySourceSchemaVersion =
            try sourceSchemaVersion(legacyStateInput)
        let vault = SecureProfileVault(
            rootURL: vaultRootURL,
            keyProvider: keyProvider
        )
        let snapshot = try vault.saveSnapshot(
            profileID: "migration-0.10.3",
            adapterVersion: "0.11.0",
            inputs: [legacyStateInput, configInput]
                .compactMap { $0 }
        )
        let preparedAt = now()
        let manifest = V011Migration0103Manifest(
            schemaVersion:
                V011Migration0103Manifest
                    .currentSchemaVersion,
            archiveID: snapshot.id,
            sourceVersion: "0.10.3",
            targetVersion: "0.11.0",
            sourceControlPlanePathHash:
                pathHash(controlRootURL),
            targetCodexHomePathHash: pathHash(codexHomeURL),
            snapshot: snapshot,
            legacyStateFile: fileSummary(
                role: Self.legacyStateRelativePath,
                input: legacyStateInput
            ),
            codexConfigFile: fileSummary(
                role: Self.codexConfigRelativePath,
                input: configInput
            ),
            legacyStateSchemaVersion: legacySourceSchemaVersion,
            legacyCurrentMode: legacyState?.currentMode.rawValue,
            legacyActiveRelayID: legacyState?.activeRelayID,
            legacyRelays: relaySummaries(legacyState),
            legacyBaseline: baselineSummary(legacyState),
            credentialBridgeProfileIDs: Array(
                Set(
                    legacyState?.credentialBridgeProfileIDs
                        ?? []
                )
            ).sorted(),
            legacyStateHadLastTransaction:
                legacyState?.lastTransaction != nil,
            legacyTransactionArtifactsPresent:
                legacyTransactionArtifactsPresent(legacyState),
            legacySnapshotArtifactsPresent:
                directoryContainsEntries(
                    controlRootURL.appendingPathComponent(
                        "ProfileVault",
                        isDirectory: true
                    )
                ),
            legacyArtifactsPreservedInPlace: true,
            preparedAt: preparedAt,
            completedAt: nil,
            adoptedProfileID: nil
        )
        try writeManifest(manifest)
        guard let persisted = try loadManifest() else {
            throw V011Migration0103Error
                .archiveVerificationFailed
        }
        try verifyArchive(persisted)
        return persisted
    }

    @discardableResult
    func completeAfterSuccessfulAdoption(
        profileID: String
    ) throws -> V011Migration0103Manifest {
        let normalized = profileID.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw V011Migration0103Error
                .invalidAdoptedProfileID
        }
        var manifest = try prepareIfNeeded()
        if let adopted = manifest.adoptedProfileID {
            guard adopted == normalized else {
                throw V011Migration0103Error
                    .completedWithDifferentProfile
            }
            return manifest
        }
        manifest.adoptedProfileID = normalized
        manifest.completedAt = now()
        try writeManifest(manifest)
        guard let persisted = try loadManifest() else {
            throw V011Migration0103Error
                .archiveVerificationFailed
        }
        try verifyArchive(persisted)
        return persisted
    }

    private func verifyArchive(
        _ manifest: V011Migration0103Manifest
    ) throws {
        try verifyPathFingerprints(manifest)
        let restored = try SecureProfileVault(
            rootURL: vaultRootURL,
            keyProvider: keyProvider
        ).loadSnapshot(manifest.snapshot)
        let restoredByPath = Dictionary(
            uniqueKeysWithValues: restored.map {
                ($0.relativePath, $0)
            }
        )
        guard restoredByPath.count == restored.count,
              verify(
                manifest.legacyStateFile,
                in: restoredByPath
              ),
              verify(
                manifest.codexConfigFile,
                in: restoredByPath
              ),
              restored.count
                == [
                    manifest.legacyStateFile,
                    manifest.codexConfigFile,
                ].filter(\.existed).count,
              manifest.archiveID == manifest.snapshot.id,
              manifest.legacyArtifactsPreservedInPlace else {
            throw V011Migration0103Error
                .archiveVerificationFailed
        }
    }

    private func verify(
        _ summary: V011Migration0103FileSummary,
        in restoredByPath: [String: SnapshotInput]
    ) -> Bool {
        guard summary.existed else {
            return restoredByPath[summary.role] == nil
                && summary.sha256 == nil
                && summary.byteCount == 0
                && summary.permissions == nil
        }
        guard let input = restoredByPath[summary.role] else {
            return false
        }
        return summary.sha256
                == SecureProfileVault.sha256(input.data)
            && summary.byteCount == input.data.count
            && summary.permissions == input.permissions
    }

    private func verifyPathFingerprints(
        _ manifest: V011Migration0103Manifest
    ) throws {
        guard manifest.sourceControlPlanePathHash
                == pathHash(controlRootURL),
              manifest.targetCodexHomePathHash
                == pathHash(codexHomeURL) else {
            throw V011Migration0103Error
                .pathFingerprintMismatch
        }
    }

    private func snapshotInput(
        at url: URL,
        relativePath: String
    ) throws -> SnapshotInput? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        try requireRegularFile(url)
        let data = try Data(contentsOf: url)
        let permissions = try filePermissions(url)
        return SnapshotInput(
            relativePath: relativePath,
            data: data,
            permissions: permissions
        )
    }

    private func requireRegularFile(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw V011Migration0103Error
                .unsafeSourceFile(url.path)
        }
    }

    private func sameSnapshotInput(
        _ lhs: SnapshotInput?,
        _ rhs: SnapshotInput?
    ) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (.some(lhs), .some(rhs)):
            return lhs.relativePath == rhs.relativePath
                && lhs.data == rhs.data
                && lhs.permissions == rhs.permissions
        default:
            return false
        }
    }

    private func sourceSchemaVersion(
        _ input: SnapshotInput?
    ) throws -> Int? {
        guard let input else { return nil }
        struct SchemaProbe: Decodable {
            let schemaVersion: Int?
        }
        return try JSONDecoder().decode(
            SchemaProbe.self,
            from: input.data
        ).schemaVersion ?? 1
    }

    private func filePermissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(
            atPath: url.path
        )
        return (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? 0o600
    }

    private func fileSummary(
        role: String,
        input: SnapshotInput?
    ) -> V011Migration0103FileSummary {
        guard let input else {
            return V011Migration0103FileSummary(
                role: role,
                existed: false,
                sha256: nil,
                byteCount: 0,
                permissions: nil
            )
        }
        return V011Migration0103FileSummary(
            role: role,
            existed: true,
            sha256: SecureProfileVault.sha256(input.data),
            byteCount: input.data.count,
            permissions: input.permissions
        )
    }

    private func relaySummaries(
        _ state: CodexStateStore.State?
    ) -> [V011Migration0103RelaySummary] {
        (state?.relayProfiles ?? []).map { profile in
            V011Migration0103RelaySummary(
                id: profile.id,
                providerID: profile.providerID,
                name: profile.name,
                baseURLHash: SecureProfileVault.sha256(
                    Data(profile.baseURL.utf8)
                ),
                wireProtocol: profile.wireProtocol.rawValue,
                defaultModel: profile.defaultModel,
                modelCount: profile.models.count
            )
        }.sorted {
            if $0.id != $1.id { return $0.id < $1.id }
            return ($0.providerID ?? "")
                < ($1.providerID ?? "")
        }
    }

    private func baselineSummary(
        _ state: CodexStateStore.State?
    ) -> V011Migration0103BaselineSummary? {
        guard let state, let baseline = state.baseline else {
            return nil
        }
        return V011Migration0103BaselineSummary(
            trust: state.officialBaselineTrust.rawValue,
            snapshotID: baseline.snapshot.id,
            snapshotProfileID: baseline.snapshot.profileID,
            adapterVersion: baseline.snapshot.adapterVersion,
            codexHomePathHash: SecureProfileVault.sha256(
                Data(baseline.codexHomePath.utf8)
            ),
            configExisted: baseline.configExisted,
            authExisted: baseline.authExisted,
            configHash: baseline.configHash,
            authHash: baseline.authHash,
            createdAt: baseline.createdAt
        )
    }

    private func legacyTransactionArtifactsPresent(
        _ state: CodexStateStore.State?
    ) -> Bool {
        state?.lastTransaction != nil
            || FileManager.default.fileExists(
                atPath: controlRootURL
                    .appendingPathComponent(
                        "provider-switch.lock"
                    ).path
            )
    }

    private func directoryContainsEntries(_ url: URL) -> Bool {
        guard let entries = try? FileManager.default
            .contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
            return false
        }
        return !entries.isEmpty
    }

    private func pathHash(_ url: URL) -> String {
        SecureProfileVault.sha256(Data(url.path.utf8))
    }

    private func writeManifest(
        _ manifest: V011Migration0103Manifest
    ) throws {
        let directory = manifestURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        try encoder.encode(manifest).write(
            to: manifestURL,
            options: .atomic
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
    }
}
