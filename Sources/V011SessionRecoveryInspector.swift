// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011SessionRecoveryInspector {
    let codexHome: URL
    let sessionRecoveryRoot: URL
    let sessionCore: any V011SessionCoreOperating

    func sessionsMatchTarget(
        providerID: String
    ) async throws -> Bool {
        // Connection detection only needs the provider index used by the
        // desktop task list. Full rollout hashing belongs to switch/recovery,
        // not a read-only minimal-request check.
        let page = try await sessionCore.list(
            codexHome: codexHome,
            limit: 1,
            offset: 0,
            provider: providerID
        )
        return page.visibleTotal == page.total
    }

    func sessionsFullySynchronized(
        providerID: String
    ) async throws -> Bool {
        let inspection = try await sessionCore.inspect(
            codexHome: codexHome,
            provider: providerID
        )
        return inspection.targetProvider == providerID
            && !inspection.needsRepair
            && inspection.rolloutFilesNeedingRepair == 0
            && inspection.sqliteProviderMismatches == 0
            && inspection.sqliteUserEventMismatches == 0
            && inspection.sqliteCwdMismatches == 0
    }

    func sessionJournalAllowsAcceptance(
        _ journal: V011SwitchJournal
    ) throws -> Bool {
        guard let path = journal.sessionJournalPath else {
            return true
        }
        let expected = sessionRecoveryRoot
            .appendingPathComponent(
                journal.id.lowercased(),
                isDirectory: true
            )
            .standardizedFileURL
        let directory = URL(fileURLWithPath: path)
            .standardizedFileURL
        guard directory == expected,
              try sessionJournalIsMaterialized(path) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let manifestURL = directory
            .appendingPathComponent("journal.json")
        struct Header: Decodable {
            let version: Int
            let transactionID: String
            let codexHome: String
            let state: String

            private enum CodingKeys: String, CodingKey {
                case version
                case transactionID = "transactionId"
                case codexHome
                case state
            }
        }
        let header = try JSONDecoder().decode(
            Header.self,
            from: try boundedRegularFileData(
                manifestURL,
                maximumBytes: 64 * 1024 * 1024
            )
        )
        guard header.version == 1,
              header.transactionID
                == journal.id.lowercased(),
              URL(fileURLWithPath: header.codexHome)
                .standardizedFileURL == codexHome else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return header.state == "rolled_back"
            || header.state == "committed"
    }

    func sessionJournalAllowsForwardCompletion(
        _ journal: V011SwitchJournal
    ) throws -> Bool {
        guard let path = journal.sessionJournalPath else {
            return false
        }
        let expected = sessionRecoveryRoot
            .appendingPathComponent(
                journal.id.lowercased(),
                isDirectory: true
            )
            .standardizedFileURL
        let directory = URL(fileURLWithPath: path)
            .standardizedFileURL
        guard directory == expected,
              try sessionJournalIsMaterialized(path) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let manifestURL = directory
            .appendingPathComponent("journal.json")
        struct Header: Decodable {
            let version: Int
            let transactionID: String
            let codexHome: String
            let state: String

            private enum CodingKeys: String, CodingKey {
                case version
                case transactionID = "transactionId"
                case codexHome
                case state
            }
        }
        let header = try JSONDecoder().decode(
            Header.self,
            from: try boundedRegularFileData(
                manifestURL,
                maximumBytes: 64 * 1024 * 1024
            )
        )
        guard header.version == 1,
              header.transactionID
                == journal.id.lowercased(),
              URL(fileURLWithPath: header.codexHome)
                .standardizedFileURL == codexHome else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        if header.state == "committed" {
            return true
        }
        guard header.state == "rollback_failed",
              journal.phase == .rollbackFailed else {
            return false
        }
        let failure = journal.message.lowercased()
        guard !failure.contains(
            "rollback_compensation_failed"
        ), !failure.contains("自动补偿也没有完成") else {
            return false
        }
        let provenPrewriteFailure =
            failure.contains("concurrent_sqlite_change")
            || failure.contains("concurrent_rollout_change")
            || failure.contains(
                "changed after session transaction"
            )
            || failure.contains(
                "refusing destructive rollback"
            )
            || failure.contains("不能自动合并的修改")
            || failure.contains("切换后新增或变更的历史会话")
        guard provenPrewriteFailure else {
            return false
        }
        // rollback_failed only becomes a forward candidate. Full live
        // configuration, Provider-label and connection checks below prove
        // target state is still intact before any outer journal is committed.
        return true
    }

    func boundedRegularFileData(
        _ url: URL,
        maximumBytes: Int
    ) throws -> Data {
        guard maximumBytes > 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let descriptor = open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = close(descriptor) }

        var before = stat()
        guard fstat(descriptor, &before) == 0,
              (before.st_mode & S_IFMT) == S_IFREG,
              before.st_size > 0,
              before.st_size <= off_t(maximumBytes) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        var result = Data()
        result.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(
                    descriptor,
                    $0.baseAddress,
                    min(
                        $0.count,
                        maximumBytes + 1 - result.count
                    )
                )
            }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumBytes else {
                throw V011SwitchError.invalidRecoveryJournal
            }
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec
                == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec
                == after.st_mtimespec.tv_nsec,
              result.count == Int(after.st_size) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return result
    }

    func sessionJournalIsMaterialized(
        _ path: String
    ) throws -> Bool {
        let directory = URL(fileURLWithPath: path)
            .standardizedFileURL
        guard FileManager.default.fileExists(
            atPath: directory.path
        ) else {
            return false
        }
        let values = try directory.resourceValues(
            forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let manifest = directory
            .appendingPathComponent("journal.json")
        guard FileManager.default.fileExists(
            atPath: manifest.path
        ) else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        try SessionSyncFileSafety.requireRegularFile(manifest)
        return true
    }
}
