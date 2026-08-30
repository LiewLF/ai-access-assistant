// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation

struct UpdateBundleIdentity: Codable, Equatable, Sendable {
    let bundleIdentifier: String
    let version: String
    let build: Int
}

struct UpdateBundleSnapshot: Codable, Equatable, Sendable {
    let identity: UpdateBundleIdentity
    let treeSHA256: String
    let fileCount: Int
    let byteCount: Int64
}

struct UpdateRecoveryPoint: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let id: String
    let transactionID: String
    let sourceAppPath: String
    let backupAppPath: String
    let identity: UpdateBundleIdentity
    let treeSHA256: String
    let fileCount: Int
    let byteCount: Int64
    let createdAtEpoch: Int64
}

enum UpdateRecoveryPhase: String, Codable, Equatable, Sendable {
    case backupVerified
    case installPendingAcceptance
    case accepted
    case rollbackRequired
    case rolledBack
    case manualRecoveryRequired
}

struct UpdateRecoveryJournal: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let transactionID: String
    let liveAppPath: String
    let recoveryPoint: UpdateRecoveryPoint
    var phase: UpdateRecoveryPhase
    var displacedAppPath: String?
    var failureCode: String?
    var updatedAtEpoch: Int64
}

struct UpdateRollbackResult: Equatable, Sendable {
    let restoredIdentity: UpdateBundleIdentity
    let displacedAppPath: String?
}

enum TrustedUpdateRecoveryError: Error, Equatable {
    case invalidTransactionID
    case unsafeRecoveryRoot
    case unsafeAppPath
    case unsupportedBundleEntry(String)
    case bundleTooLarge
    case bundleIdentityMismatch
    case recoveryPointExists
    case journalMissing
    case invalidJournalState
    case recoveryPointTampered
    case staleRollbackArtifact
    case rollbackFailed
    case rollbackCompensationFailed
}

extension TrustedUpdateRecoveryError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidTransactionID:
            return "更新事务编号无效"
        case .unsafeRecoveryRoot:
            return "更新恢复目录不安全"
        case .unsafeAppPath:
            return "应用路径不安全"
        case .unsupportedBundleEntry(let path):
            return "应用包含不支持的文件类型：\(path)"
        case .bundleTooLarge:
            return "应用超过恢复点安全处理范围"
        case .bundleIdentityMismatch:
            return "应用身份不匹配"
        case .recoveryPointExists:
            return "更新恢复点已存在"
        case .journalMissing:
            return "更新恢复记录不存在"
        case .invalidJournalState:
            return "更新恢复记录状态无效"
        case .recoveryPointTampered:
            return "更新恢复点校验失败"
        case .staleRollbackArtifact:
            return "回退路径已有未处理文件"
        case .rollbackFailed:
            return "应用回退失败"
        case .rollbackCompensationFailed:
            return "应用回退失败且原版本恢复失败"
        }
    }
}

enum TrustedUpdateBundleInspector {
    static let maximumEntries = 50_000
    static let maximumBytes: Int64 = 2_147_483_648

    static func inspect(
        appURL: URL,
        expectedBundleIdentifier: String
    ) throws -> UpdateBundleSnapshot {
        let app = appURL.standardizedFileURL
        guard app.isFileURL,
              app.path.hasPrefix("/"),
              app.pathExtension == "app" else {
            throw TrustedUpdateRecoveryError.unsafeAppPath
        }
        let root = try metadata(app, relativePath: ".")
        guard root.kind == .directory else {
            throw TrustedUpdateRecoveryError.unsafeAppPath
        }

        let infoURL = app.appendingPathComponent(
            "Contents/Info.plist",
            isDirectory: false
        )
        let infoMetadata = try metadata(
            infoURL,
            relativePath: "Contents/Info.plist"
        )
        guard infoMetadata.kind == .regular else {
            throw TrustedUpdateRecoveryError.unsafeAppPath
        }
        let infoData = try Data(contentsOf: infoURL)
        guard let plist = try PropertyListSerialization
                .propertyList(from: infoData, options: [], format: nil)
                as? [String: Any],
              let bundleIdentifier = plist["CFBundleIdentifier"] as? String,
              bundleIdentifier == expectedBundleIdentifier,
              let version = plist["CFBundleShortVersionString"] as? String,
              !version.isEmpty,
              let buildString = plist["CFBundleVersion"] as? String,
              let build = Int(buildString),
              build > 0 else {
            throw TrustedUpdateRecoveryError.bundleIdentityMismatch
        }

        var entries: [(relativePath: String, metadata: EntryMetadata)] = [
            (".", root),
        ]
        try collectEntries(
            root: app,
            directory: app,
            relativePath: "",
            entries: &entries
        )
        guard entries.count <= maximumEntries else {
            throw TrustedUpdateRecoveryError.bundleTooLarge
        }
        entries.sort { $0.relativePath < $1.relativePath }

        var hasher = SHA256()
        var fileCount = 0
        var byteCount: Int64 = 0
        for entry in entries {
            update(&hasher, text: entry.metadata.kind.marker)
            update(&hasher, text: entry.relativePath)
            update(&hasher, text: String(entry.metadata.permissions))
            update(&hasher, text: String(entry.metadata.size))
            guard entry.metadata.kind == .regular else { continue }
            fileCount += 1
            byteCount += entry.metadata.size
            guard byteCount <= maximumBytes else {
                throw TrustedUpdateRecoveryError.bundleTooLarge
            }
            let fileURL = app.appendingPathComponent(entry.relativePath)
            try hashFile(fileURL, into: &hasher)
        }
        return UpdateBundleSnapshot(
            identity: UpdateBundleIdentity(
                bundleIdentifier: bundleIdentifier,
                version: version,
                build: build
            ),
            treeSHA256: Data(hasher.finalize()).hexString,
            fileCount: fileCount,
            byteCount: byteCount
        )
    }

    private enum EntryKind {
        case directory
        case regular

        var marker: String {
            switch self {
            case .directory: return "directory"
            case .regular: return "regular"
            }
        }
    }

    private struct EntryMetadata {
        let kind: EntryKind
        let permissions: UInt16
        let size: Int64
    }

    private static func collectEntries(
        root: URL,
        directory: URL,
        relativePath: String,
        entries: inout [(relativePath: String, metadata: EntryMetadata)]
    ) throws {
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.path)
            .sorted()
        for name in names {
            let childRelative = relativePath.isEmpty
                ? name
                : "\(relativePath)/\(name)"
            guard !name.contains("/") else {
                throw TrustedUpdateRecoveryError.unsupportedBundleEntry(
                    childRelative
                )
            }
            let child = root.appendingPathComponent(childRelative)
            let value = try metadata(child, relativePath: childRelative)
            entries.append((childRelative, value))
            guard entries.count <= maximumEntries else {
                throw TrustedUpdateRecoveryError.bundleTooLarge
            }
            if value.kind == .directory {
                try collectEntries(
                    root: root,
                    directory: child,
                    relativePath: childRelative,
                    entries: &entries
                )
            }
        }
    }

    private static func metadata(
        _ url: URL,
        relativePath: String
    ) throws -> EntryMetadata {
        var value = stat()
        guard Darwin.lstat(url.path, &value) == 0 else {
            throw TrustedUpdateRecoveryError.unsupportedBundleEntry(
                relativePath
            )
        }
        let fileType = value.st_mode & S_IFMT
        if fileType == S_IFDIR {
            return EntryMetadata(
                kind: .directory,
                permissions: UInt16(value.st_mode & 0o7777),
                size: 0
            )
        }
        if fileType == S_IFREG {
            return EntryMetadata(
                kind: .regular,
                permissions: UInt16(value.st_mode & 0o7777),
                size: Int64(value.st_size)
            )
        }
        throw TrustedUpdateRecoveryError.unsupportedBundleEntry(
            relativePath
        )
    }

    private static func update(
        _ hasher: inout SHA256,
        text: String
    ) {
        let data = Data(text.utf8)
        var length = UInt64(data.count).bigEndian
        withUnsafeBytes(of: &length) {
            hasher.update(data: Data($0))
        }
        hasher.update(data: data)
    }

    private static func hashFile(
        _ url: URL,
        into hasher: inout SHA256
    ) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let chunk = try handle.read(upToCount: 1_048_576),
              !chunk.isEmpty {
            hasher.update(data: chunk)
        }
    }
}

struct TrustedUpdateRecoveryCoordinator {
    let rootURL: URL
    let expectedBundleIdentifier: String
    private let fileManager = FileManager.default

    init(rootURL: URL, expectedBundleIdentifier: String) {
        self.rootURL = rootURL.standardizedFileURL
        self.expectedBundleIdentifier = expectedBundleIdentifier
    }

    func createRecoveryPoint(
        liveAppURL: URL,
        transactionID: String,
        nowEpoch: Int64
    ) throws -> UpdateRecoveryPoint {
        try requireSafeTransactionID(transactionID)
        let live = try safeLiveAppURL(liveAppURL)
        return try withExclusiveLock {
            let journalURL = self.journalURL(transactionID)
            guard !fileManager.fileExists(atPath: journalURL.path) else {
                throw TrustedUpdateRecoveryError.recoveryPointExists
            }
            let source = try TrustedUpdateBundleInspector.inspect(
                appURL: live,
                expectedBundleIdentifier: expectedBundleIdentifier
            )
            let pointID = "recovery-\(transactionID)-build\(source.identity.build)"
            let destination = rootURL.appendingPathComponent(
                "\(pointID).app",
                isDirectory: true
            )
            let candidate = rootURL.appendingPathComponent(
                ".candidate-\(transactionID).app",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: destination.path),
                  !fileManager.fileExists(atPath: candidate.path) else {
                throw TrustedUpdateRecoveryError.recoveryPointExists
            }
            do {
                try fileManager.copyItem(at: live, to: candidate)
                let candidateSnapshot = try TrustedUpdateBundleInspector.inspect(
                    appURL: candidate,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                guard candidateSnapshot == source else {
                    throw TrustedUpdateRecoveryError.recoveryPointTampered
                }
                try fileManager.moveItem(at: candidate, to: destination)
                let stored = try TrustedUpdateBundleInspector.inspect(
                    appURL: destination,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                guard stored == source else {
                    throw TrustedUpdateRecoveryError.recoveryPointTampered
                }
                let point = UpdateRecoveryPoint(
                    schemaVersion: 1,
                    id: pointID,
                    transactionID: transactionID,
                    sourceAppPath: live.path,
                    backupAppPath: destination.path,
                    identity: stored.identity,
                    treeSHA256: stored.treeSHA256,
                    fileCount: stored.fileCount,
                    byteCount: stored.byteCount,
                    createdAtEpoch: nowEpoch
                )
                let journal = UpdateRecoveryJournal(
                    schemaVersion: 1,
                    transactionID: transactionID,
                    liveAppPath: live.path,
                    recoveryPoint: point,
                    phase: .backupVerified,
                    displacedAppPath: nil,
                    failureCode: nil,
                    updatedAtEpoch: nowEpoch
                )
                try saveJournalUnlocked(journal)
                return point
            } catch {
                try? removeManagedItem(candidate)
                try? removeManagedItem(destination)
                throw error
            }
        }
    }

    @discardableResult
    func markInstallPendingAcceptance(
        transactionID: String,
        nowEpoch: Int64
    ) throws -> UpdateRecoveryJournal {
        try requireSafeTransactionID(transactionID)
        return try withExclusiveLock {
            var journal = try loadJournalUnlocked(transactionID)
            guard journal.phase == .backupVerified else {
                throw TrustedUpdateRecoveryError.invalidJournalState
            }
            try verifyRecoveryPoint(journal.recoveryPoint)
            journal.phase = .installPendingAcceptance
            journal.updatedAtEpoch = nowEpoch
            try saveJournalUnlocked(journal)
            return journal
        }
    }

    @discardableResult
    func acceptUpdate(
        transactionID: String,
        nowEpoch: Int64
    ) throws -> UpdateRecoveryJournal {
        try requireSafeTransactionID(transactionID)
        return try withExclusiveLock {
            var journal = try loadJournalUnlocked(transactionID)
            guard journal.phase == .installPendingAcceptance else {
                throw TrustedUpdateRecoveryError.invalidJournalState
            }
            try verifyRecoveryPoint(journal.recoveryPoint)
            journal.phase = .accepted
            journal.updatedAtEpoch = nowEpoch
            try saveJournalUnlocked(journal)
            return journal
        }
    }

    func journal(transactionID: String) throws -> UpdateRecoveryJournal {
        try requireSafeTransactionID(transactionID)
        return try withExclusiveLock {
            try loadJournalUnlocked(transactionID)
        }
    }

    func rollback(
        transactionID: String,
        nowEpoch: Int64
    ) throws -> UpdateRollbackResult {
        try requireSafeTransactionID(transactionID)
        return try withExclusiveLock {
            var journal = try loadJournalUnlocked(transactionID)
            if journal.phase == .rolledBack {
                return UpdateRollbackResult(
                    restoredIdentity: journal.recoveryPoint.identity,
                    displacedAppPath: journal.displacedAppPath
                )
            }
            guard journal.phase == .installPendingAcceptance
                    || journal.phase == .rollbackRequired else {
                throw TrustedUpdateRecoveryError.invalidJournalState
            }
            do {
                try verifyRecoveryPoint(journal.recoveryPoint)
            } catch {
                journal.phase = .manualRecoveryRequired
                journal.failureCode = "recovery_point_tampered"
                journal.updatedAtEpoch = nowEpoch
                try saveJournalUnlocked(journal)
                throw TrustedUpdateRecoveryError.recoveryPointTampered
            }

            let live = try safeLiveAppURL(
                URL(fileURLWithPath: journal.liveAppPath)
            )
            let parent = live.deletingLastPathComponent()
            let stem = live.deletingPathExtension().lastPathComponent
            let candidate = parent.appendingPathComponent(
                ".\(stem)-restore-\(transactionID).app",
                isDirectory: true
            )
            let quarantine = parent.appendingPathComponent(
                ".\(stem)-failed-\(transactionID).app",
                isDirectory: true
            )
            guard !fileManager.fileExists(atPath: candidate.path),
                  !fileManager.fileExists(atPath: quarantine.path) else {
                throw TrustedUpdateRecoveryError.staleRollbackArtifact
            }

            let recoveryURL = URL(
                fileURLWithPath: journal.recoveryPoint.backupAppPath,
                isDirectory: true
            )
            try fileManager.copyItem(at: recoveryURL, to: candidate)
            do {
                let candidateSnapshot = try TrustedUpdateBundleInspector.inspect(
                    appURL: candidate,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                guard matches(candidateSnapshot, point: journal.recoveryPoint) else {
                    throw TrustedUpdateRecoveryError.recoveryPointTampered
                }
            } catch {
                try? fileManager.removeItem(at: candidate)
                throw error
            }

            journal.phase = .rollbackRequired
            journal.failureCode = nil
            journal.updatedAtEpoch = nowEpoch
            try saveJournalUnlocked(journal)

            let liveExists = fileManager.fileExists(atPath: live.path)
            var retainedURL: URL?
            if liveExists {
                let displacedSnapshot = try TrustedUpdateBundleInspector.inspect(
                    appURL: live,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                let retained = rootURL.appendingPathComponent(
                    "failed-\(transactionID)-build\(displacedSnapshot.identity.build).app",
                    isDirectory: true
                )
                guard !fileManager.fileExists(atPath: retained.path) else {
                    try? fileManager.removeItem(at: candidate)
                    throw TrustedUpdateRecoveryError.staleRollbackArtifact
                }
                retainedURL = retained
                try fileManager.moveItem(at: live, to: quarantine)
            }
            do {
                try fileManager.moveItem(at: candidate, to: live)
                let restored = try TrustedUpdateBundleInspector.inspect(
                    appURL: live,
                    expectedBundleIdentifier: expectedBundleIdentifier
                )
                guard matches(restored, point: journal.recoveryPoint) else {
                    throw TrustedUpdateRecoveryError.rollbackFailed
                }
            } catch {
                try? fileManager.removeItem(at: candidate)
                try? fileManager.removeItem(at: live)
                if liveExists {
                    do {
                        try fileManager.moveItem(at: quarantine, to: live)
                    } catch {
                        journal.phase = .manualRecoveryRequired
                        journal.failureCode = "rollback_compensation_failed"
                        journal.updatedAtEpoch = nowEpoch
                        try? saveJournalUnlocked(journal)
                        throw TrustedUpdateRecoveryError.rollbackCompensationFailed
                    }
                }
                journal.phase = .manualRecoveryRequired
                journal.failureCode = "rollback_failed"
                journal.updatedAtEpoch = nowEpoch
                try? saveJournalUnlocked(journal)
                throw TrustedUpdateRecoveryError.rollbackFailed
            }

            var displacedPath: String?
            if liveExists, let retainedURL {
                do {
                    try fileManager.moveItem(at: quarantine, to: retainedURL)
                    displacedPath = retainedURL.path
                } catch {
                    // The failed version remains recoverable beside the live App.
                    displacedPath = quarantine.path
                }
            }
            journal.phase = .rolledBack
            journal.displacedAppPath = displacedPath
            journal.failureCode = nil
            journal.updatedAtEpoch = nowEpoch
            try saveJournalUnlocked(journal)
            return UpdateRollbackResult(
                restoredIdentity: journal.recoveryPoint.identity,
                displacedAppPath: displacedPath
            )
        }
    }

    private func verifyRecoveryPoint(
        _ point: UpdateRecoveryPoint
    ) throws {
        guard point.schemaVersion == 1,
              safeTransactionID(point.transactionID),
              point.id == "recovery-\(point.transactionID)-build\(point.identity.build)" else {
            throw TrustedUpdateRecoveryError.recoveryPointTampered
        }
        let backup = URL(
            fileURLWithPath: point.backupAppPath,
            isDirectory: true
        ).standardizedFileURL
        guard backup.deletingLastPathComponent().path == rootURL.path,
              backup.lastPathComponent == "\(point.id).app" else {
            throw TrustedUpdateRecoveryError.recoveryPointTampered
        }
        let snapshot = try TrustedUpdateBundleInspector.inspect(
            appURL: backup,
            expectedBundleIdentifier: expectedBundleIdentifier
        )
        guard matches(snapshot, point: point) else {
            throw TrustedUpdateRecoveryError.recoveryPointTampered
        }
    }

    private func matches(
        _ snapshot: UpdateBundleSnapshot,
        point: UpdateRecoveryPoint
    ) -> Bool {
        snapshot.identity == point.identity
            && snapshot.treeSHA256 == point.treeSHA256
            && snapshot.fileCount == point.fileCount
            && snapshot.byteCount == point.byteCount
    }

    private func safeLiveAppURL(_ value: URL) throws -> URL {
        let live = value.standardizedFileURL
        guard live.isFileURL,
              live.path.hasPrefix("/"),
              live.pathExtension == "app",
              live.path != "/",
              live.path != rootURL.path,
              !live.path.hasPrefix(rootURL.path + "/") else {
            throw TrustedUpdateRecoveryError.unsafeAppPath
        }
        return live
    }

    private func loadJournalUnlocked(
        _ transactionID: String
    ) throws -> UpdateRecoveryJournal {
        let url = journalURL(transactionID)
        guard fileManager.fileExists(atPath: url.path) else {
            throw TrustedUpdateRecoveryError.journalMissing
        }
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_mode & 0o077 == 0 else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_048_576,
              let journal = try? JSONDecoder().decode(
                  UpdateRecoveryJournal.self,
                  from: data
              ),
              journal.schemaVersion == 1,
              journal.transactionID == transactionID,
              journal.recoveryPoint.transactionID == transactionID,
              journal.recoveryPoint.sourceAppPath == journal.liveAppPath else {
            throw TrustedUpdateRecoveryError.invalidJournalState
        }
        _ = try safeLiveAppURL(URL(fileURLWithPath: journal.liveAppPath))
        return journal
    }

    private func saveJournalUnlocked(
        _ journal: UpdateRecoveryJournal
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(journal)
        let destination = journalURL(journal.transactionID)
        try data.write(to: destination, options: .atomic)
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: destination.path
        )
    }

    private func journalURL(_ transactionID: String) -> URL {
        rootURL.appendingPathComponent(
            "update-\(transactionID).json",
            isDirectory: false
        )
    }

    private func withExclusiveLock<T>(_ body: () throws -> T) throws -> T {
        try prepareRoot()
        let lockURL = rootURL.appendingPathComponent(
            ".update-recovery.lock",
            isDirectory: false
        )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(),
              Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR) == 0,
              flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        try requireRootIdentity()
        return try body()
    }

    private func prepareRoot() throws {
        guard rootURL.isFileURL,
              rootURL.path.hasPrefix("/"),
              rootURL.path != "/" else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
        if fileManager.fileExists(atPath: rootURL.path) {
            try requireRootIdentity()
        } else {
            try fileManager.createDirectory(
                at: rootURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: rootURL.path
        )
        try requireRootIdentity()
    }

    private func requireRootIdentity() throws {
        var metadata = stat()
        guard Darwin.lstat(rootURL.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              metadata.st_uid == getuid(),
              metadata.st_mode & 0o077 == 0 else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
    }

    private func removeManagedItem(_ url: URL) throws {
        let standardized = url.standardizedFileURL
        guard standardized.deletingLastPathComponent().path == rootURL.path else {
            throw TrustedUpdateRecoveryError.unsafeRecoveryRoot
        }
        if fileManager.fileExists(atPath: standardized.path) {
            try fileManager.removeItem(at: standardized)
        }
    }

    private func requireSafeTransactionID(_ value: String) throws {
        guard safeTransactionID(value) else {
            throw TrustedUpdateRecoveryError.invalidTransactionID
        }
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
}

struct UpdateRecoveryRetentionPlan: Equatable, Sendable {
    let keptPointIDs: [String]
    let candidatePointIDs: [String]
    let blockedPointIDs: [String]
    let automaticDeletionAllowed: Bool
}

enum UpdateRecoveryRetentionPlanner {
    static func plan(
        points: [UpdateRecoveryPoint],
        activeTransactionIDs: Set<String>,
        lastKnownGoodPointID: String?,
        acceptedNewVersion: Bool,
        keepNewestCount: Int = 2
    ) -> UpdateRecoveryRetentionPlan {
        var blocked: Set<String> = []
        var unique: [String: UpdateRecoveryPoint] = [:]
        for point in points {
            guard point.schemaVersion == 1,
                  !point.id.isEmpty,
                  point.treeSHA256.count == 64,
                  unique[point.id] == nil else {
                blocked.insert(point.id)
                continue
            }
            unique[point.id] = point
        }
        let ordered = unique.values.sorted {
            if $0.createdAtEpoch == $1.createdAtEpoch {
                return $0.id < $1.id
            }
            return $0.createdAtEpoch > $1.createdAtEpoch
        }
        var protected: Set<String> = Set(
            ordered.prefix(max(0, keepNewestCount)).map(\.id)
        )
        protected.formUnion(
            ordered
                .filter { activeTransactionIDs.contains($0.transactionID) }
                .map(\.id)
        )
        if let lastKnownGoodPointID {
            protected.insert(lastKnownGoodPointID)
        }
        if !acceptedNewVersion {
            protected.formUnion(ordered.map(\.id))
        }
        blocked.formUnion(protected.filter { unique[$0] == nil })
        let kept = ordered.map(\.id).filter { protected.contains($0) }
        let candidates = acceptedNewVersion
            ? ordered.map(\.id).filter {
                !protected.contains($0) && !blocked.contains($0)
            }
            : []
        return UpdateRecoveryRetentionPlan(
            keptPointIDs: kept,
            candidatePointIDs: candidates,
            blockedPointIDs: blocked.sorted(),
            automaticDeletionAllowed: false
        )
    }
}

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
