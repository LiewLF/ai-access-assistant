// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011SwitchJournalStore {
    let rootURL: URL
    private let fileManager = FileManager.default
    let faultInjector:
        @Sendable (V011AcceptedCurrentFaultPoint) throws -> Void
    let directorySynchronizer:
        @Sendable (Int32) -> Int32

    init(
        rootURL: URL,
        faultInjector: @escaping @Sendable
            (V011AcceptedCurrentFaultPoint) throws -> Void = { _ in },
        directorySynchronizer: @escaping @Sendable
            (Int32) -> Int32 = { Darwin.fsync($0) }
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.faultInjector = faultInjector
        self.directorySynchronizer = directorySynchronizer
    }

    func save(_ journal: V011SwitchJournal) throws {
        try withJournalLock { _ in
            let destination = journalURL(journal.id)
            let currentData: Data?
            if fileManager.fileExists(atPath: destination.path) {
                try SessionSyncFileSafety.requireRegularFile(
                    destination
                )
                currentData = try Data(contentsOf: destination)
            } else {
                currentData = nil
            }
            if let currentData {
                try preserveRawRecordPreimage(
                    currentData,
                    for: destination
                )
            }
            let candidate = try currentData.map {
                try preservingUnknownJSONFields(
                    encoded(journal),
                    from: $0,
                    knownRootKeys: [
                        "version", "id", "codexHomePath",
                        "sourceConfigHash", "sourceConfigExisted",
                        "targetConfigHash", "targetProvider",
                        "targetProfileID", "configSnapshot",
                        "stateExisted", "originLedgerExisted",
                        "startedAt", "updatedAt", "phase",
                        "sessionJournalPath", "message",
                        "failureStage", "nextAction",
                        "protectsPostSwitchSessions",
                        "acceptedCurrent", "stateCASManaged",
                        "sourceManagedStateHash",
                        "targetManagedStateHash",
                        "forwardManagedStateHash",
                        "targetOriginLedgerHash",
                        "stateEvidenceVersion", "stateEvidenceMAC",
                        "configTransactionID",
                        "configTransactionPhase", "historyPolicy",
                        "reservationID", "reservationHash",
                        "supersedeIntents",
                    ]
                )
            } ?? encoded(journal)
            try SessionSyncAtomicFile.write(
                candidate,
                to: destination,
                expectedHash: currentData.map {
                    TOMLSemanticEngine.sha256($0)
                },
                permissions: 0o600,
                modificationDate: nil
            )
        }
    }

    func journalHash(_ id: String) throws -> String {
        try withJournalLock { _ in
            let url = journalURL(id)
            try SessionSyncFileSafety.requireRegularFile(url)
            guard let hash = SessionSyncFileSafety
                    .hashIfPresent(url) else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return hash
        }
    }

    func load(_ id: String) throws -> V011SwitchJournal {
        try load(journalURL(id))
    }

    func pending() throws -> [V011SwitchJournal] {
        try allJournals().filter(\.phase.isPending)
            .sorted { $0.startedAt < $1.startedAt }
    }

    func pendingReadOnly() throws -> [V011SwitchJournal] {
        try allJournals(readOnly: true).filter(\.phase.isPending)
    }

    func pendingConfigCutover() throws -> [V011SwitchJournal] {
        try allJournals().filter { journal in
            guard journal.phase.isPending else { return false }
            if let phase = journal.configTransactionPhase {
                return phase != .committed
            }
            return true
        }
        .sorted { $0.startedAt < $1.startedAt }
    }

    func latestCommitted() throws -> V011SwitchJournal? {
        try allJournals()
            .filter { $0.phase == .committed }
            .max { $0.updatedAt < $1.updatedAt }
    }

    func committedSessionTransactions() throws
        -> [V011SwitchJournal] {
        try allJournals()
            .filter {
                $0.phase == .committed
                    && $0.configTransactionPhase == .committed
                    && (
                        $0.reservationID != nil
                            || !($0.supersedeIntents ?? []).isEmpty
                    )
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    @discardableResult
    func archiveCommittedKeepingLatest(_ keepCount: Int = 5)
        throws -> V011SessionRetentionPlan {
        try withJournalLock { rootDescriptor in
            let journals = try allJournalsUnlocked()
            let committed = journals
                .filter { $0.phase == .committed }
                .sorted { $0.updatedAt > $1.updatedAt }
            let receiptRoot = rootURL.deletingLastPathComponent()
                .appendingPathComponent(
                    "SessionTransactions",
                    isDirectory: true
                )
            let receipts = (try? V011SessionTransactionReceiptStore(
                rootURL: receiptRoot
            ).all()) ?? []
            let graph = V011SessionRetentionReferenceGraph(
                activeTransactionIDs: Set(
                    journals.filter { $0.phase.isPending }.map(\.id)
                ),
                pendingTransactionIDs: Set(
                    journals.filter { $0.phase.isPending }.map(\.id)
                ),
                diagnosticReferenceIDs: Set(
                    receipts.flatMap {
                        [$0.id, $0.configTransactionID]
                    }
                )
            )
            var expectedHashes: [String: String] = [:]
            for journal in committed {
                let source = journalURL(journal.id)
                if let data = try? Data(contentsOf: source) {
                    expectedHashes[journal.id] =
                        TOMLSemanticEngine.sha256(data)
                }
            }
            let plan = V011SessionRetentionPlanner.plan(
                terminalIDs: committed.map(\.id),
                graph: graph,
                expectedHashes: expectedHashes,
                keepCount: keepCount
            )
            guard plan.isSafe else { return plan }
            guard !plan.candidateIDs.isEmpty else { return plan }
            let archive = rootURL.appendingPathComponent(
                "Archive",
                isDirectory: true
            )
            try prepareRoot(archive)
            guard rootDescriptorMatchesCanonicalPath(
                rootDescriptor
            ) else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            for journal in committed where plan.candidateIDs.contains(journal.id) {
                let source = journalURL(journal.id)
                let data = try Data(contentsOf: source)
                guard TOMLSemanticEngine.sha256(data)
                        == plan.expectedHashes[journal.id] else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                let destination = archive.appendingPathComponent(
                    "\(journal.id)-\(Int(journal.updatedAt.timeIntervalSince1970)).json"
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                try fileManager.moveItem(at: source, to: destination)
                try fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: destination.path
                )
            }
            return plan
        }
    }

    private func allJournals(readOnly: Bool = false) throws -> [V011SwitchJournal] {
        guard fileManager.fileExists(atPath: rootURL.path) else {
            return []
        }
        try prepareRoot(rootURL, readOnly: readOnly)
        return try allJournalsUnlocked()
    }

    private func allJournalsUnlocked() throws -> [V011SwitchJournal] {
        return try fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        .filter { $0.pathExtension == "json" }
        .map(load)
    }

    private func load(_ url: URL) throws -> V011SwitchJournal {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let journal = try decoded(
            Data(contentsOf: url),
            expectedID:
                url.deletingPathExtension()
                    .lastPathComponent
        )
        return journal
    }

    func encoded(
        _ journal: V011SwitchJournal
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [
            .prettyPrinted,
            .sortedKeys,
        ]
        return try encoder.encode(journal)
    }

    func decoded(
        _ data: Data,
        expectedID: String
    ) throws -> V011SwitchJournal {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let journal = try decoder.decode(
            V011SwitchJournal.self,
            from: data
        )
        guard journal.version == 1,
              journal.id == expectedID,
              URL(fileURLWithPath: journal.codexHomePath)
                .standardizedFileURL.path
                == journal.codexHomePath else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return journal
    }

    func withJournalLock<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        try prepareRoot(rootURL)
        let rootDescriptor = try openRootDescriptor()
        defer { _ = Darwin.close(rootDescriptor) }
        guard rootDescriptorMatchesCanonicalPath(
            rootDescriptor
        ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let descriptor = Darwin.openat(
            rootDescriptor,
            ".switch-journal.lock",
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              Darwin.fchmod(
                  descriptor,
                  S_IRUSR | S_IWUSR
              ) == 0,
              rootDescriptorMatchesCanonicalPath(
                rootDescriptor
              ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        guard flock(
            descriptor,
            LOCK_EX | LOCK_NB
        ) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        guard rootDescriptorMatchesCanonicalPath(
            rootDescriptor
        ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try body(rootDescriptor)
    }

    func journalURL(_ id: String) -> URL {
        rootURL.appendingPathComponent("\(id).json")
    }

    private func prepareRoot(_ url: URL, readOnly: Bool = false) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw V011SwitchError.invalidRecoveryJournal
            }
        } else {
            guard !readOnly else { throw V011SwitchError.invalidRecoveryJournal }
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        guard !readOnly else { return }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
    }
}
