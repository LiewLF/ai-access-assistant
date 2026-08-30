// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct V011HistoryRecoveryPointer:
    Codable,
    Equatable,
    Sendable {
    enum Kind: String, Codable, Sendable {
        case repair
        case externalImport
    }

    enum Phase: String, Codable, Sendable {
        case prepared
        case committed
    }

    let version: Int
    let transactionID: String
    let journalPath: String
    let phase: Phase
    let kind: Kind?

    init(
        version: Int,
        transactionID: String,
        journalPath: String,
        phase: Phase,
        kind: Kind? = nil
    ) {
        self.version = version
        self.transactionID = transactionID
        self.journalPath = journalPath
        self.phase = phase
        self.kind = kind
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case transactionID = "transactionId"
        case journalPath
        case phase
        case kind
    }
}

enum V011HistoryJournalState: Equatable {
    case absent
    case staleEmpty
    case materialized
}

enum V011HistoryRecoveryStore {
    static func prepareRecoveryRoot(
        _ url: URL
    ) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(
                forKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw SessionCoreClientError
                    .invalidJournalRoot
            }
        } else {
            try manager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                ]
            )
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }

    static func validatedTransactionID(
        _ value: String
    ) throws -> String {
        guard let parsed = UUID(uuidString: value),
              parsed.uuidString.lowercased()
                == value.lowercased() else {
            throw SessionCoreClientError.invalidTransactionID
        }
        return parsed.uuidString.lowercased()
    }

    static func validatedRecoveryJournal(
        _ journal: URL,
        recoveryRoot: URL,
        transactionID: String
    ) throws -> URL {
        guard isSafeDirectory(recoveryRoot) else {
            throw SessionCoreClientError.invalidJournalRoot
        }
        let transactionID = try validatedTransactionID(
            transactionID
        )
        let expected = recoveryRoot.appendingPathComponent(
            transactionID,
            isDirectory: true
        ).standardizedFileURL
        let candidate = journal.standardizedFileURL
        guard candidate.path == expected.path,
              SessionSyncFileSafety.isDescendant(
                candidate.path,
                of: recoveryRoot.standardizedFileURL.path
              ) else {
            throw SessionCoreClientError.invalidJournal
        }
        return candidate
    }

    static func recoveryJournalState(
        _ journal: URL,
        recoveryRoot: URL,
        transactionID: String
    ) throws -> V011HistoryJournalState {
        let journal = try validatedRecoveryJournal(
            journal,
            recoveryRoot: recoveryRoot,
            transactionID: transactionID
        )
        let manager = FileManager.default
        guard manager.fileExists(atPath: journal.path) else {
            return .absent
        }
        let values = try journal.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw SessionCoreClientError.invalidJournal
        }
        let manifest = journal.appendingPathComponent(
            "journal.json"
        )
        guard manager.fileExists(atPath: manifest.path) else {
            let entries = try manager.contentsOfDirectory(
                at: journal,
                includingPropertiesForKeys: [
                    .isSymbolicLinkKey,
                ],
                options: []
            )
            guard entries.isEmpty else {
                throw SessionCoreClientError.invalidJournal
            }
            return .staleEmpty
        }
        let manifestValues = try manifest.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        guard manifestValues.isRegularFile == true,
              manifestValues.isSymbolicLink != true else {
            throw SessionCoreClientError.invalidJournal
        }
        return .materialized
    }

    static func saveRecoveryJournalPointer(
        _ record: V011HistoryRecoveryPointer,
        at pointer: URL,
        recoveryRoot: URL
    ) throws {
        try prepareRecoveryRoot(
            pointer.deletingLastPathComponent()
        )
        guard record.version == 1 else {
            throw SessionCoreClientError.invalidJournal
        }
        _ = try validatedRecoveryJournal(
            URL(fileURLWithPath: record.journalPath),
            recoveryRoot: recoveryRoot,
            transactionID: record.transactionID
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: pointer, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pointer.path
        )
    }

    static func readRecoveryJournalPointer(
        at pointer: URL,
        recoveryRoot: URL
    ) throws -> V011HistoryRecoveryPointer? {
        guard FileManager.default.fileExists(
            atPath: pointer.path
        ) else {
            return nil
        }
        let values = try pointer.resourceValues(
            forKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
            ]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 16 * 1024 else {
            throw SessionCoreClientError.invalidJournal
        }
        let data = try Data(contentsOf: pointer)
        let record: V011HistoryRecoveryPointer
        if let decoded = try? JSONDecoder().decode(
            V011HistoryRecoveryPointer.self,
            from: data
        ) {
            record = decoded
        } else if let object = try? JSONSerialization
            .jsonObject(with: data) as? [String: Any],
                  let path = object["journalPath"] as? String {
            let legacyJournal = URL(fileURLWithPath: path)
                .standardizedFileURL
            record = V011HistoryRecoveryPointer(
                version: 1,
                transactionID:
                    legacyJournal.lastPathComponent.lowercased(),
                journalPath: legacyJournal.path,
                phase: .committed
            )
        } else {
            throw SessionCoreClientError.invalidJournal
        }
        guard record.version == 1 else {
            throw SessionCoreClientError.invalidJournal
        }
        _ = try validatedRecoveryJournal(
            URL(fileURLWithPath: record.journalPath),
            recoveryRoot: recoveryRoot,
            transactionID: record.transactionID
        )
        return record
    }

    static func archiveRecoveryPointer(
        at pointer: URL,
        expectedTransactionID: String,
        expectedHash: String
    ) throws {
        guard FileManager.default.fileExists(atPath: pointer.path) else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        let data = try Data(contentsOf: pointer)
        guard Build65RecoveryOperationKey.sha256(data) == expectedHash else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        let recoveryRoot = pointer.deletingLastPathComponent()
        guard let record = try readRecoveryJournalPointer(
            at: pointer,
            recoveryRoot: recoveryRoot
        ), record.transactionID.lowercased()
            == expectedTransactionID.lowercased() else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        let archive = pointer.deletingLastPathComponent()
            .appendingPathComponent(
                "Archive",
                isDirectory: true
            )
        try prepareRecoveryRoot(archive)
        let destination = archive.appendingPathComponent(
            "last-repair-"
                + String(Int(Date().timeIntervalSince1970))
                + "-"
                + UUID().uuidString
                + ".json"
        )
        try FileManager.default.moveItem(
            at: pointer,
            to: destination
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    /// Archives journal first, then revalidates and archives pointer. If the
    /// pointer CAS fails, the journal move is best-effort restored so cleanup
    /// never silently loses the live pointer.
    static func archiveRecoveryRecord(
        at pointer: URL,
        expectedTransactionID: String,
        expectedHash: String,
        journal: URL?,
        expectedJournalHash: String?
    ) throws {
        let manager = FileManager.default
        let archive = pointer.deletingLastPathComponent()
            .appendingPathComponent("Archive", isDirectory: true)
        try prepareRecoveryRoot(archive)
        let nonce = UUID().uuidString
        let pointerDestination = archive.appendingPathComponent(
            "last-repair-\(Int(Date().timeIntervalSince1970))-\(nonce).json"
        )
        let journalDestination = journal.map {
            archive.appendingPathComponent(
                "\($0.lastPathComponent)-\(Int(Date().timeIntervalSince1970))-\(nonce)"
            )
        }
        if let journal {
            try validateRecoveryJournalForArchive(
                journal,
                expectedHash: expectedJournalHash
            )
            guard let journalDestination else {
                throw SessionCoreClientError.invalidJournal
            }
            try manager.moveItem(at: journal, to: journalDestination)
        }
        do {
            try validatePointerForArchive(
                pointer,
                expectedTransactionID: expectedTransactionID,
                expectedHash: expectedHash
            )
            try manager.moveItem(at: pointer, to: pointerDestination)
        } catch {
            if let journalDestination,
               let journal,
               manager.fileExists(atPath: journalDestination.path) {
                try? manager.moveItem(at: journalDestination, to: journal)
            }
            throw error
        }
        try manager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: pointerDestination.path
        )
        if let journalDestination {
            try manager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: journalDestination.path
            )
        }
    }

    static func pointerContentHash(
        at pointer: URL
    ) throws -> String {
        let values = try pointer.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? Int.max) <= 16 * 1024 else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        return Build65RecoveryOperationKey.sha256(
            try Data(contentsOf: pointer)
        )
    }

    static func journalContentHash(
        _ journal: URL,
        recoveryRoot: URL,
        transactionID: String
    ) -> String? {
        guard let validated = try? validatedRecoveryJournal(
            journal,
            recoveryRoot: recoveryRoot,
            transactionID: transactionID
        ),
        let data = try? Data(
            contentsOf: validated.appendingPathComponent(
                "journal.json"
            )
        ) else {
            return nil
        }
        return Build65RecoveryOperationKey.sha256(data)
    }

    private static func isSafeDirectory(
        _ url: URL
    ) -> Bool {
        guard let values = try? url.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        ) else {
            return false
        }
        return values.isDirectory == true
            && values.isSymbolicLink != true
    }

    private static func validatePointerForArchive(
        _ pointer: URL,
        expectedTransactionID: String,
        expectedHash: String
    ) throws {
        let data = try Data(contentsOf: pointer)
        guard Build65RecoveryOperationKey.sha256(data) == expectedHash,
              let record = try readRecoveryJournalPointer(
                  at: pointer,
                  recoveryRoot: pointer.deletingLastPathComponent()
              ),
              record.transactionID.lowercased()
                  == expectedTransactionID.lowercased() else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
    }

    private static func validateRecoveryJournalForArchive(
        _ journal: URL,
        expectedHash: String?
    ) throws {
        let values = try journal.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw SessionCoreClientError.recoveryPointerChanged
        }
        if let expectedHash {
            let transactionID = journal.lastPathComponent
            guard journalContentHash(
                journal,
                recoveryRoot: journal.deletingLastPathComponent(),
                transactionID: transactionID
            ) == expectedHash else {
                throw SessionCoreClientError.recoveryPointerChanged
            }
        } else {
            guard try FileManager.default.contentsOfDirectory(
                at: journal,
                includingPropertiesForKeys: nil,
                options: []
            ).isEmpty else {
                throw SessionCoreClientError.recoveryPointerChanged
            }
        }
    }
}
