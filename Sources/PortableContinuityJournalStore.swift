// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

struct PortableContinuityApplyJournalStore {
    let rootURL: URL

    func save(_ journal: PortableContinuityApplyJournal) throws {
        try prepareRoot()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let file = url(journal.id)
        try SessionSyncAtomicFile.write(
            encoder.encode(journal),
            to: file,
            expectedHash: SessionSyncFileSafety.hashIfPresent(file),
            permissions: 0o600,
            modificationDate: nil
        )
    }

    func pending() throws -> [PortableContinuityApplyJournal] {
        try all().filter(\.phase.isPending)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func all() throws -> [PortableContinuityApplyJournal] {
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return []
        }
        try validateExistingRoot()
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
        .filter { $0.pathExtension.lowercased() == "json" }
        .map { file in
            try SessionSyncFileSafety.requireRegularFile(file)
            let journal = try decoder.decode(
                PortableContinuityApplyJournal.self,
                from: Data(contentsOf: file)
            )
            guard journal.version == 1,
                file.lastPathComponent == "\(journal.id).json"
            else {
                throw PortableContinuityApplyError.invalidJournal
            }
            return journal
        }
    }

    private func prepareRoot() throws {
        if FileManager.default.fileExists(atPath: rootURL.path) {
            try validateExistingRoot()
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

    private func validateExistingRoot() throws {
        let values = try rootURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            throw PortableContinuityApplyError.invalidJournal
        }
    }

    private func url(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }
}
