// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Darwin
import Foundation

enum SessionVaultError: LocalizedError, Equatable {
    case invalidCodexHome
    case invalidDestination
    case destinationInsideCodexHome
    case destinationExists
    case noSessions
    case tooManyFiles
    case oversizedFile(String)
    case sourceTooLarge
    case unsafePath(String)
    case concurrentSourceChange(String)
    case invalidManifest(String)
    case checksumMismatch(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidCodexHome:
            return "Codex数据目录无效，未导出会话备份"
        case .invalidDestination:
            return "备份位置无效；请选择当前Codex目录之外的普通文件夹"
        case .destinationInsideCodexHome:
            return "备份不能保存在当前Codex数据目录内"
        case .destinationExists:
            return "同名会话备份已经存在；请换一个名称"
        case .noSessions:
            return "没有找到可导出的Codex会话文件"
        case .tooManyFiles:
            return "会话文件超过2000个安全上限，未导出"
        case .oversizedFile(let path):
            return "单个会话文件超过64 MB安全上限：\(path)"
        case .sourceTooLarge:
            return "会话文件合计超过512 MB安全上限，未导出"
        case .unsafePath(let path):
            return "发现不安全的会话路径：\(path)"
        case .concurrentSourceChange(let path):
            return "导出期间会话仍在变化，请稍后重试：\(path)"
        case .invalidManifest(let reason):
            return "会话备份清单无效：\(reason)"
        case .checksumMismatch(let path):
            return "会话备份校验失败：\(path)"
        case .writeFailed(let reason):
            return "会话备份写入失败：\(reason)"
        }
    }
}

struct SessionVaultFileEntry: Codable, Equatable, Sendable {
    let relativePath: String
    let sizeBytes: Int64
    let sha256: String
    let archived: Bool
}

struct SessionVaultManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let formatIdentifier = "ai-access-codex-session-vault"

    let schemaVersion: Int
    let format: String
    let createdAt: String
    let appVersion: String
    let appBuild: String
    let fileCount: Int
    let activeFileCount: Int
    let archivedFileCount: Int
    let totalBytes: Int64
    let exclusions: [String]
    let files: [SessionVaultFileEntry]
}

struct SessionVaultVerification: Equatable, Sendable {
    let packageURL: URL
    let fileCount: Int
    let activeFileCount: Int
    let archivedFileCount: Int
    let totalBytes: Int64
    let ignoredFileCount: Int
    let manifestSHA256: String
}

struct SessionVaultExportSummary: Equatable, Sendable {
    let packageURL: URL
    let fileCount: Int
    let activeFileCount: Int
    let archivedFileCount: Int
    let totalBytes: Int64
    let manifestSHA256: String
}

enum SessionVault {
    static let manifestName = "session-vault-manifest.json"
    static let maximumFiles = 2_000
    static let maximumFileBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumTotalBytes: Int64 = 512 * 1_024 * 1_024
    static let maximumManifestBytes = 4 * 1_024 * 1_024
    static let excludedSurfaces = [
        "auth.json",
        "config.toml",
        "state_5.sqlite",
        "Keychain与API Key",
        "AI接入助手恢复密钥",
    ]

    private struct SourceEntry {
        let url: URL
        let relativePath: String
        let sizeBytes: Int64
        let modificationDate: Date?
        let archived: Bool
    }

    static func export(
        codexHome: URL,
        destination: URL,
        appVersion: String = AppReleaseMetadata.version,
        appBuild: String = AppReleaseMetadata.build,
        progress: (Int, Int) -> Void = { _, _ in }
    ) throws -> SessionVaultExportSummary {
        let home = try realDirectory(
            codexHome,
            error: .invalidCodexHome
        )
        let target = destination.standardizedFileURL
        guard target.isFileURL,
              target.path.hasPrefix("/"),
              target.pathExtension.lowercased() == "codexbackup",
              target.lastPathComponent != ".codexbackup" else {
            throw SessionVaultError.invalidDestination
        }
        let parent = try realDirectory(
            target.deletingLastPathComponent(),
            error: .invalidDestination
        )
        let normalizedTarget = parent.appendingPathComponent(
            target.lastPathComponent,
            isDirectory: true
        ).standardizedFileURL
        if isWithin(normalizedTarget.path, root: home.path) {
            throw SessionVaultError.destinationInsideCodexHome
        }
        guard !FileManager.default.fileExists(
            atPath: normalizedTarget.path
        ) else {
            throw SessionVaultError.destinationExists
        }

        let sources = try collectSources(home: home)
        guard !sources.isEmpty else {
            throw SessionVaultError.noSessions
        }
        let stage = parent.appendingPathComponent(
            ".\(normalizedTarget.lastPathComponent).stage-\(UUID().uuidString)",
            isDirectory: true
        )
        let manager = FileManager.default
        do {
            try manager.createDirectory(
                at: stage,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SessionVaultError.writeFailed(
                safeError(error)
            )
        }
        var published = false
        defer {
            if !published,
               manager.fileExists(atPath: stage.path) {
                try? manager.removeItem(at: stage)
            }
        }

        var entries: [SessionVaultFileEntry] = []
        entries.reserveCapacity(sources.count)
        for (index, source) in sources.enumerated() {
            try Task.checkCancellation()
            let output = try safeChild(
                root: stage,
                relativePath: source.relativePath
            )
            do {
                try manager.createDirectory(
                    at: output.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                guard manager.createFile(
                    atPath: output.path,
                    contents: nil,
                    attributes: [.posixPermissions: 0o600]
                ) else {
                    throw SessionVaultError.writeFailed(
                        "无法创建备份文件"
                    )
                }
                let copiedDigest = try copyAndHash(
                    source: source.url,
                    destination: output,
                    maximumBytes: source.sizeBytes
                )
                let after = try regularFileMetadata(source.url)
                let sourceDigest = try sha256File(
                    source.url,
                    maximumBytes: maximumFileBytes
                )
                guard after.sizeBytes == source.sizeBytes,
                      after.modificationDate == source.modificationDate,
                      sourceDigest == copiedDigest else {
                    throw SessionVaultError.concurrentSourceChange(
                        source.relativePath
                    )
                }
                entries.append(
                    SessionVaultFileEntry(
                        relativePath: source.relativePath,
                        sizeBytes: source.sizeBytes,
                        sha256: copiedDigest,
                        archived: source.archived
                    )
                )
                progress(index + 1, sources.count)
            } catch let error as SessionVaultError {
                throw error
            } catch {
                throw SessionVaultError.writeFailed(
                    safeError(error)
                )
            }
        }

        let totalBytes = entries.reduce(Int64(0)) {
            $0 + $1.sizeBytes
        }
        let activeCount = entries.filter { !$0.archived }.count
        let archivedCount = entries.count - activeCount
        let manifest = SessionVaultManifest(
            schemaVersion: SessionVaultManifest.currentSchemaVersion,
            format: SessionVaultManifest.formatIdentifier,
            createdAt: ISO8601DateFormatter.sessionVault.string(
                from: Date()
            ),
            appVersion: appVersion,
            appBuild: appBuild,
            fileCount: entries.count,
            activeFileCount: activeCount,
            archivedFileCount: archivedCount,
            totalBytes: totalBytes,
            exclusions: excludedSurfaces,
            files: entries.sorted {
                $0.relativePath < $1.relativePath
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData: Data
        do {
            manifestData = try encoder.encode(manifest)
        } catch {
            throw SessionVaultError.writeFailed("清单无法编码")
        }
        guard manifestData.count <= maximumManifestBytes else {
            throw SessionVaultError.invalidManifest("清单超过4 MB")
        }
        let manifestURL = stage.appendingPathComponent(manifestName)
        do {
            try manifestData.write(
                to: manifestURL,
                options: .withoutOverwriting
            )
            try manager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            try FileHandle(forWritingTo: manifestURL)
                .synchronizeAndClose()
        } catch {
            throw SessionVaultError.writeFailed(
                safeError(error)
            )
        }

        _ = try verify(packageURL: stage)
        guard !manager.fileExists(atPath: normalizedTarget.path) else {
            throw SessionVaultError.destinationExists
        }
        do {
            try manager.moveItem(
                at: stage,
                to: normalizedTarget
            )
            published = true
            syncDirectory(parent)
        } catch {
            throw SessionVaultError.writeFailed(
                safeError(error)
            )
        }
        return SessionVaultExportSummary(
            packageURL: normalizedTarget,
            fileCount: entries.count,
            activeFileCount: activeCount,
            archivedFileCount: archivedCount,
            totalBytes: totalBytes,
            manifestSHA256: sha256(manifestData)
        )
    }

    static func verify(
        packageURL: URL
    ) throws -> SessionVaultVerification {
        let root = try realDirectory(
            packageURL,
            error: .invalidManifest("备份不是普通目录")
        )
        let manifestURL = root.appendingPathComponent(manifestName)
        let metadata: (sizeBytes: Int64, modificationDate: Date?)
        do {
            metadata = try regularFileMetadata(manifestURL)
        } catch {
            throw SessionVaultError.invalidManifest("缺少校验清单")
        }
        guard metadata.sizeBytes > 0,
              metadata.sizeBytes <= Int64(maximumManifestBytes) else {
            throw SessionVaultError.invalidManifest("清单大小无效")
        }
        let data: Data
        let manifest: SessionVaultManifest
        do {
            data = try Data(
                contentsOf: manifestURL,
                options: .mappedIfSafe
            )
            manifest = try JSONDecoder().decode(
                SessionVaultManifest.self,
                from: data
            )
        } catch {
            throw SessionVaultError.invalidManifest("JSON无法解码")
        }
        guard manifest.schemaVersion
                == SessionVaultManifest.currentSchemaVersion,
              manifest.format
                == SessionVaultManifest.formatIdentifier,
              manifest.fileCount == manifest.files.count,
              manifest.activeFileCount
                + manifest.archivedFileCount
                == manifest.fileCount,
              manifest.fileCount > 0,
              manifest.fileCount <= maximumFiles,
              manifest.totalBytes >= 0,
              Set(manifest.exclusions)
                .isSuperset(of: excludedSurfaces) else {
            throw SessionVaultError.invalidManifest("Schema或汇总字段不一致")
        }

        var paths = Set<String>()
        var totalBytes: Int64 = 0
        var activeCount = 0
        for entry in manifest.files {
            try Task.checkCancellation()
            guard paths.insert(entry.relativePath).inserted,
                  entry.sizeBytes >= 0,
                  entry.sizeBytes <= maximumFileBytes,
                  isSHA256(entry.sha256),
                  entry.relativePath.hasSuffix(".jsonl") else {
                throw SessionVaultError.invalidManifest(
                    "文件条目重复或字段无效"
                )
            }
            let first = entry.relativePath.split(
                separator: "/",
                omittingEmptySubsequences: false
            ).first.map(String.init)
            guard first == "sessions"
                    || first == "archived_sessions",
                  entry.archived
                    == (first == "archived_sessions") else {
                throw SessionVaultError.invalidManifest(
                    "活跃与归档路径不一致"
                )
            }
            let file = try safeChild(
                root: root,
                relativePath: entry.relativePath
            )
            let fileMetadata: (
                sizeBytes: Int64,
                modificationDate: Date?
            )
            do {
                fileMetadata = try regularFileMetadata(file)
            } catch {
                throw SessionVaultError.checksumMismatch(
                    entry.relativePath
                )
            }
            guard fileMetadata.sizeBytes == entry.sizeBytes,
                  try sha256File(
                    file,
                    maximumBytes: maximumFileBytes
                  ) == entry.sha256 else {
                throw SessionVaultError.checksumMismatch(
                    entry.relativePath
                )
            }
            let addition = totalBytes.addingReportingOverflow(
                entry.sizeBytes
            )
            guard !addition.overflow,
                  addition.partialValue <= maximumTotalBytes else {
                throw SessionVaultError.sourceTooLarge
            }
            totalBytes = addition.partialValue
            if !entry.archived { activeCount += 1 }
        }
        guard totalBytes == manifest.totalBytes,
              activeCount == manifest.activeFileCount,
              manifest.fileCount - activeCount
                == manifest.archivedFileCount else {
            throw SessionVaultError.invalidManifest("文件统计与清单不一致")
        }

        let inventory = try packageInventory(root: root)
        guard inventory.jsonlPaths == paths else {
            let mismatch = inventory.jsonlPaths
                .symmetricDifference(paths)
                .sorted()
                .first ?? "JSONL清单"
            throw SessionVaultError.checksumMismatch(mismatch)
        }
        return SessionVaultVerification(
            packageURL: root,
            fileCount: manifest.fileCount,
            activeFileCount: manifest.activeFileCount,
            archivedFileCount: manifest.archivedFileCount,
            totalBytes: manifest.totalBytes,
            ignoredFileCount: inventory.ignoredFiles,
            manifestSHA256: sha256(data)
        )
    }

    static func looksLikeVault(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "codexbackup"
            || FileManager.default.fileExists(
                atPath: url.appendingPathComponent(
                    manifestName
                ).path
            )
    }

    private static func collectSources(
        home: URL
    ) throws -> [SourceEntry] {
        let manager = FileManager.default
        var result: [SourceEntry] = []
        var totalBytes: Int64 = 0
        for rootName in ["sessions", "archived_sessions"] {
            let root = home.appendingPathComponent(
                rootName,
                isDirectory: true
            )
            guard manager.fileExists(atPath: root.path) else {
                continue
            }
            _ = try realDirectory(
                root,
                error: .unsafePath(rootName)
            )
            guard let enumerator = manager.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ],
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let item as URL in enumerator {
                let values = try item.resourceValues(
                    forKeys: [
                        .isDirectoryKey,
                        .isRegularFileKey,
                        .isSymbolicLinkKey,
                    ]
                )
                if values.isSymbolicLink == true {
                    enumerator.skipDescendants()
                    throw SessionVaultError.unsafePath(
                        "符号链接：\(item.path)"
                    )
                }
                guard values.isRegularFile == true,
                      item.pathExtension.lowercased()
                        == "jsonl",
                      item.lastPathComponent.hasPrefix(
                        "rollout-"
                      ) else { continue }
                guard result.count < maximumFiles else {
                    throw SessionVaultError.tooManyFiles
                }
                let metadata = try regularFileMetadata(item)
                let canonicalRoot = root
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let canonicalItem = item
                    .resolvingSymlinksInPath()
                    .standardizedFileURL
                let prefix = canonicalRoot.path.hasSuffix("/")
                    ? canonicalRoot.path
                    : canonicalRoot.path + "/"
                guard canonicalItem.path.hasPrefix(prefix) else {
                    throw SessionVaultError.unsafePath(
                        "路径越界：\(canonicalItem.path)"
                    )
                }
                let suffix = String(
                    canonicalItem.path.dropFirst(prefix.count)
                )
                let relativePath = rootName + "/" + suffix
                guard metadata.sizeBytes <= maximumFileBytes else {
                    throw SessionVaultError.oversizedFile(
                        relativePath
                    )
                }
                let addition = totalBytes.addingReportingOverflow(
                    metadata.sizeBytes
                )
                guard !addition.overflow,
                      addition.partialValue
                        <= maximumTotalBytes else {
                    throw SessionVaultError.sourceTooLarge
                }
                totalBytes = addition.partialValue
                result.append(
                    SourceEntry(
                        url: canonicalItem,
                        relativePath: relativePath,
                        sizeBytes: metadata.sizeBytes,
                        modificationDate:
                            metadata.modificationDate,
                        archived:
                            rootName == "archived_sessions"
                    )
                )
            }
        }
        return result.sorted {
            $0.relativePath < $1.relativePath
        }
    }

    private static func packageInventory(
        root: URL
    ) throws -> (jsonlPaths: Set<String>, ignoredFiles: Int) {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ],
            options: []
        ) else {
            throw SessionVaultError.invalidManifest("无法读取备份目录")
        }
        var jsonlPaths = Set<String>()
        var ignored = 0
        let canonicalRoot = root.resolvingSymlinksInPath()
            .standardizedFileURL
        let prefix = canonicalRoot.path.hasSuffix("/")
            ? canonicalRoot.path : canonicalRoot.path + "/"
        for case let item as URL in enumerator {
            let values = try item.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ]
            )
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                throw SessionVaultError.unsafePath(
                    "符号链接：\(item.path)"
                )
            }
            guard values.isRegularFile == true else { continue }
            let canonicalItem = item.resolvingSymlinksInPath()
                .standardizedFileURL
            guard canonicalItem.path.hasPrefix(prefix) else {
                throw SessionVaultError.unsafePath(
                    "路径越界：\(canonicalItem.path)"
                )
            }
            let relative = String(
                canonicalItem.path.dropFirst(prefix.count)
            )
            if canonicalItem.pathExtension.lowercased()
                == "jsonl" {
                jsonlPaths.insert(relative)
            } else if relative != manifestName {
                ignored += 1
            }
        }
        return (jsonlPaths, ignored)
    }

    private static func regularFileMetadata(
        _ url: URL
    ) throws -> (sizeBytes: Int64, modificationDate: Date?) {
        var information = stat()
        let status = url.withUnsafeFileSystemRepresentation {
            path -> Int32 in
            guard let path else { return -1 }
            return Darwin.lstat(path, &information)
        }
        guard status == 0,
              (information.st_mode & S_IFMT) == S_IFREG else {
            throw SessionVaultError.unsafePath(
                "不是普通文件(status=\(status), mode=\(information.st_mode))：\(url.path)"
            )
        }
        let seconds = TimeInterval(
            information.st_mtimespec.tv_sec
        )
        let nanoseconds = TimeInterval(
            information.st_mtimespec.tv_nsec
        ) / 1_000_000_000
        let size = Int64(information.st_size)
        guard size >= 0 else {
            throw SessionVaultError.unsafePath(url.path)
        }
        return (
            size,
            Date(timeIntervalSince1970: seconds + nanoseconds)
        )
    }

    private static func realDirectory(
        _ url: URL,
        error: SessionVaultError
    ) throws -> URL {
        let candidate = url.standardizedFileURL
        guard candidate.isFileURL,
              candidate.path.hasPrefix("/"),
              let values = try? candidate.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw error
        }
        return candidate.resolvingSymlinksInPath()
            .standardizedFileURL
    }

    private static func safeChild(
        root: URL,
        relativePath: String
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"),
              !relativePath.contains("\\") else {
            throw SessionVaultError.unsafePath(relativePath)
        }
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        guard !components.isEmpty,
              components.allSatisfy({
                !$0.isEmpty && $0 != "." && $0 != ".."
              }) else {
            throw SessionVaultError.unsafePath(relativePath)
        }
        let child = components.reduce(root) {
            $0.appendingPathComponent(String($1))
        }.standardizedFileURL
        guard isWithin(child.path, root: root.path),
              child.path != root.path else {
            throw SessionVaultError.unsafePath(relativePath)
        }
        return child
    }

    private static func copyAndHash(
        source: URL,
        destination: URL,
        maximumBytes: Int64
    ) throws -> String {
        let input = try FileHandle(forReadingFrom: source)
        let output = try FileHandle(forWritingTo: destination)
        defer {
            try? input.close()
            try? output.close()
        }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try input.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            let addition = total.addingReportingOverflow(
                Int64(chunk.count)
            )
            guard !addition.overflow,
                  addition.partialValue <= maximumBytes else {
                throw SessionVaultError.concurrentSourceChange(
                    source.lastPathComponent
                )
            }
            total = addition.partialValue
            hasher.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        guard total == maximumBytes else {
            throw SessionVaultError.concurrentSourceChange(
                source.lastPathComponent
            )
        }
        try output.synchronize()
        return hex(hasher.finalize())
    }

    private static func sha256File(
        _ url: URL,
        maximumBytes: Int64
    ) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: Int64 = 0
        while let chunk = try handle.read(upToCount: 64 * 1_024),
              !chunk.isEmpty {
            let addition = total.addingReportingOverflow(
                Int64(chunk.count)
            )
            guard !addition.overflow,
                  addition.partialValue <= maximumBytes else {
                throw SessionVaultError.sourceTooLarge
            }
            total = addition.partialValue
            hasher.update(data: chunk)
        }
        return hex(hasher.finalize())
    }

    private static func sha256(_ data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private static func hex(
        _ digest: some Sequence<UInt8>
    ) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.unicodeScalars.allSatisfy {
            (48...57).contains($0.value)
                || (97...102).contains($0.value)
        }
    }

    private static func isWithin(
        _ path: String,
        root: String
    ) -> Bool {
        path == root || path.hasPrefix(
            root.hasSuffix("/") ? root : root + "/"
        )
    }

    private static func syncDirectory(_ url: URL) {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = fsync(descriptor)
        _ = close(descriptor)
    }

    private static func safeError(_ error: Error) -> String {
        let value = (error as NSError).localizedDescription
        return String(value.prefix(240))
    }
}

private extension FileHandle {
    func synchronizeAndClose() throws {
        try synchronize()
        try close()
    }
}

private extension ISO8601DateFormatter {
    static let sessionVault: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        return formatter
    }()
}
