// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011AdoptionPhase: String, Codable, CaseIterable {
    case prepared
    case credentialStored
    case ledgerWritten
    case stateWritten
    case manifestCompleted
    case committed
    case rollbackRequired
    case rolledBack
    case rollbackFailed

    var isPending: Bool {
        ![.committed, .rolledBack].contains(self)
    }
}

enum V011AdoptionFaultPoint: String, CaseIterable, Sendable {
    case prepared
    case credentialStored
    case ledgerWritten
    case stateWritten
    case manifestCompleted
    case beforeCommit
}

struct V011AdoptionJournal: Codable, Equatable, Identifiable {
    let version: Int
    let id: String
    let codexHomePath: String
    let sourceConfigHash: String
    let profileID: String
    let credentialReference: String
    let previousCredentialExisted: Bool
    let stateExisted: Bool
    let originLedgerExisted: Bool
    let migrationManifestExisted: Bool
    let snapshot: SnapshotManifest
    let startedAt: Date
    var updatedAt: Date
    var phase: V011AdoptionPhase
    var message: String
}

enum V011AdoptionTransactionError: LocalizedError {
    case pendingRecovery
    case invalidJournal
    case configurationChanged
    case rollbackFailed(String)

    var errorDescription: String? {
        switch self {
        case .pendingRecovery:
            return "发现未完成的中转接管，请先一键恢复"
        case .invalidJournal:
            return "中转接管恢复记录无法安全读取"
        case .configurationChanged:
            return "接管期间Codex设置被其他程序改变，已停止自动恢复"
        case let .rollbackFailed(message):
            return "中转接管自动恢复未完成：\(message)"
        }
    }
}

struct V011AdoptionJournalStore {
    let rootURL: URL

    func save(_ journal: V011AdoptionJournal) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try SessionSyncAtomicFile.write(
            encoder.encode(journal),
            to: url(journal.id),
            expectedHash: SessionSyncFileSafety.hashIfPresent(
                url(journal.id)
            ),
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func pending() throws -> [V011AdoptionJournal] {
        try all().filter(\.phase.isPending)
            .sorted { $0.startedAt < $1.startedAt }
    }

    private func all() throws -> [V011AdoptionJournal] {
        guard FileManager.default.fileExists(
            atPath: rootURL.path
        ) else {
            return []
        }
        try prepareRoot()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [
                .skipsHiddenFiles,
                .skipsSubdirectoryDescendants,
            ]
        )
        .filter { $0.pathExtension == "json" }
        .map { file in
            try SessionSyncFileSafety.requireRegularFile(file)
            let journal = try decoder.decode(
                V011AdoptionJournal.self,
                from: Data(contentsOf: file)
            )
            guard journal.version == 1,
                  file.lastPathComponent
                    == "\(journal.id).json" else {
                throw V011AdoptionTransactionError
                    .invalidJournal
            }
            return journal
        }
    }

    private func prepareRoot() throws {
        if FileManager.default.fileExists(
            atPath: rootURL.path
        ) {
            let values = try rootURL.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw V011AdoptionTransactionError
                    .invalidJournal
            }
        } else {
            try FileManager.default.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
    }

    private func url(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }
}

struct V011AdoptionTransactionCoordinator {
    static let statePath = "assistant/v011-state.json"
    static let ledgerPath =
        "assistant/session-origin-ledger.vault"
    static let migrationPath =
        "assistant/migration-0103-manifest.json"
    static let previousCredentialPath =
        "credential/previous-value"

    let codexHome: URL
    let controlRoot: URL
    let credentialStore: any FableCredentialStore
    let keyProvider: () throws -> Data

    var journalStore: V011AdoptionJournalStore {
        V011AdoptionJournalStore(
            rootURL: controlRoot.appendingPathComponent(
                "AdoptionTransactions",
                isDirectory: true
            )
        )
    }

    func begin(
        profileID: String,
        credentialReference: String,
        previousCredential: String?
    ) throws -> V011AdoptionJournal {
        guard try journalStore.pending().isEmpty else {
            throw V011AdoptionTransactionError
                .pendingRecovery
        }
        guard !profileID.isEmpty,
              !credentialReference.isEmpty else {
            throw V011AdoptionTransactionError
                .invalidJournal
        }
        let configURL = codexHome
            .appendingPathComponent("config.toml")
        try SessionSyncFileSafety.requireRegularFile(configURL)
        let configHash = SecureProfileVault.sha256(
            try Data(contentsOf: configURL)
        )
        let stateURL = v011StateURL
        let ledgerURL = originLedgerURL
        let migrationURL = migrationManifestURL
        var inputs: [SnapshotInput] = []
        try append(
            stateURL,
            relativePath: Self.statePath,
            to: &inputs
        )
        try append(
            ledgerURL,
            relativePath: Self.ledgerPath,
            to: &inputs
        )
        try append(
            migrationURL,
            relativePath: Self.migrationPath,
            to: &inputs
        )
        if let previousCredential {
            inputs.append(
                SnapshotInput(
                    relativePath:
                        Self.previousCredentialPath,
                    data: Data(previousCredential.utf8),
                    permissions: 0o600
                )
            )
        }
        let snapshot = try vault.saveSnapshot(
            profileID: "adoption-\(profileID)",
            adapterVersion: "0.11.0",
            inputs: inputs
        )
        let now = Date()
        let journal = V011AdoptionJournal(
            version: 1,
            id: UUID().uuidString.lowercased(),
            codexHomePath:
                codexHome.standardizedFileURL.path,
            sourceConfigHash: configHash,
            profileID: profileID,
            credentialReference: credentialReference,
            previousCredentialExisted:
                previousCredential != nil,
            stateExisted: FileManager.default.fileExists(
                atPath: stateURL.path
            ),
            originLedgerExisted:
                FileManager.default.fileExists(
                    atPath: ledgerURL.path
                ),
            migrationManifestExisted:
                FileManager.default.fileExists(
                    atPath: migrationURL.path
                ),
            snapshot: snapshot,
            startedAt: now,
            updatedAt: now,
            phase: .prepared,
            message: "已建立中转接管恢复点"
        )
        try journalStore.save(journal)
        return journal
    }

    func update(
        _ journal: inout V011AdoptionJournal,
        phase: V011AdoptionPhase,
        message: String
    ) throws {
        journal.phase = phase
        journal.updatedAt = Date()
        journal.message = message
        try journalStore.save(journal)
    }

    func rollback(
        _ journal: inout V011AdoptionJournal
    ) throws {
        do {
            try update(
                &journal,
                phase: .rollbackRequired,
                message: "接管未完成，正在恢复"
            )
            try verifyUnchangedConfiguration(journal)
            let inputs = try vault.loadSnapshot(
                journal.snapshot
            )
            let byPath = Dictionary(
                uniqueKeysWithValues: inputs.map {
                    ($0.relativePath, $0)
                }
            )
            try restore(
                v011StateURL,
                input: byPath[Self.statePath],
                existed: journal.stateExisted
            )
            try restore(
                originLedgerURL,
                input: byPath[Self.ledgerPath],
                existed: journal.originLedgerExisted
            )
            try restore(
                migrationManifestURL,
                input: byPath[Self.migrationPath],
                existed: journal.migrationManifestExisted
            )
            if journal.previousCredentialExisted {
                guard let input = byPath[
                    Self.previousCredentialPath
                ],
                let value = String(
                    data: input.data,
                    encoding: .utf8
                ) else {
                    throw V011AdoptionTransactionError
                        .invalidJournal
                }
                try credentialStore.store(
                    value,
                    reference: journal.credentialReference
                )
            } else {
                guard byPath[
                    Self.previousCredentialPath
                ] == nil else {
                    throw V011AdoptionTransactionError
                        .invalidJournal
                }
                try credentialStore.delete(
                    reference: journal.credentialReference
                )
            }
            try update(
                &journal,
                phase: .rolledBack,
                message: "未完成接管已恢复"
            )
        } catch {
            try? update(
                &journal,
                phase: .rollbackFailed,
                message: "接管恢复尚未完成"
            )
            throw V011AdoptionTransactionError
                .rollbackFailed(error.localizedDescription)
        }
    }

    func recoverPending() throws -> Int {
        var restored = 0
        for var journal in try journalStore
            .pending().reversed() {
            try rollback(&journal)
            restored += 1
        }
        return restored
    }

    private var vault: SecureProfileVault {
        SecureProfileVault(
            rootURL: controlRoot.appendingPathComponent(
                "AdoptionVault",
                isDirectory: true
            ),
            keyProvider: keyProvider
        )
    }

    private var v011StateURL: URL {
        controlRoot
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent("state.json")
    }

    private var originLedgerURL: URL {
        controlRoot
            .appendingPathComponent(
                "SessionOriginLedger",
                isDirectory: true
            )
            .appendingPathComponent("ledger.vault")
    }

    private var migrationManifestURL: URL {
        controlRoot
            .appendingPathComponent("V011", isDirectory: true)
            .appendingPathComponent(
                "Migration0103",
                isDirectory: true
            )
            .appendingPathComponent("manifest.json")
    }

    private func append(
        _ url: URL,
        relativePath: String,
        to inputs: inout [SnapshotInput]
    ) throws {
        guard FileManager.default.fileExists(
            atPath: url.path
        ) else {
            return
        }
        try SessionSyncFileSafety.requireRegularFile(url)
        let attributes = try FileManager.default
            .attributesOfItem(atPath: url.path)
        let permissions = (
            attributes[.posixPermissions] as? NSNumber
        )?.intValue ?? 0o600
        inputs.append(
            SnapshotInput(
                relativePath: relativePath,
                data: try Data(contentsOf: url),
                permissions: permissions
            )
        )
    }

    private func restore(
        _ url: URL,
        input: SnapshotInput?,
        existed: Bool
    ) throws {
        if existed {
            guard let input else {
                throw V011AdoptionTransactionError
                    .invalidJournal
            }
            try SessionSyncAtomicFile.write(
                input.data,
                to: url,
                expectedHash:
                    SessionSyncFileSafety.hashIfPresent(url),
                permissions: input.permissions,
                modificationDate: nil
            )
        } else if FileManager.default.fileExists(
            atPath: url.path
        ) {
            try SessionSyncFileSafety.requireRegularFile(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func verifyUnchangedConfiguration(
        _ journal: V011AdoptionJournal
    ) throws {
        guard codexHome.standardizedFileURL.path
                == journal.codexHomePath else {
            throw V011AdoptionTransactionError
                .invalidJournal
        }
        let configURL = codexHome
            .appendingPathComponent("config.toml")
        try SessionSyncFileSafety.requireRegularFile(configURL)
        guard SecureProfileVault.sha256(
            try Data(contentsOf: configURL)
        ) == journal.sourceConfigHash else {
            throw V011AdoptionTransactionError
                .configurationChanged
        }
    }
}
