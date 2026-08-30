// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum V011ExternalSessionImportIssueKind:
    String, Equatable, Sendable {
    case invalidRollout
    case invalidThreadID
    case existingThreadConflict
    case duplicateSourceThread
    case oversizedFile
}

struct V011ExternalSessionImportIssue:
    Identifiable, Equatable, Sendable {
    var id: String {
        kind.rawValue + "|" + relativePath
    }

    let relativePath: String
    let kind: V011ExternalSessionImportIssueKind
    let detail: String
}

struct V011ExternalSessionImportPreview:
    Equatable, Sendable {
    let sourceFolderName: String
    let vaultIntegrityVerified: Bool
    let vaultActiveSessionCount: Int
    let vaultArchivedSessionCount: Int
    let jsonlFileCount: Int
    let parsedRolloutCount: Int
    let importableSessionCount: Int
    let existingThreadConflictCount: Int
    let duplicateSourceThreadCount: Int
    let invalidFileCount: Int
    let totalBytes: Int64
    let issues: [V011ExternalSessionImportIssue]

    var readyForImport: Bool {
        importableSessionCount > 0 && issues.isEmpty
    }
}

enum V011ExternalSessionImportPreflightError:
    LocalizedError, Equatable {
    case sourceOverlapsCurrentCodexHome
    case sourceTooLarge
    case tooManyCurrentSessions
    case stalledCurrentSessionListing

    var errorDescription: String? {
        switch self {
        case .sourceOverlapsCurrentCodexHome:
            return "请选择当前Codex目录之外的外部备份文件夹"
        case .sourceTooLarge:
            return "外部会话目录超过只读预检的512 MB安全上限"
        case .tooManyCurrentSessions:
            return "当前会话数量超过20000条，无法安全完成Thread ID冲突核对"
        case .stalledCurrentSessionListing:
            return "当前会话分页没有继续返回数据，已停止冲突核对"
        }
    }
}

enum V011ExternalSessionImportPreflightScanner {
    static let maximumFiles = 2_000
    static let maximumFileBytes: Int64 = 64 * 1_024 * 1_024
    static let maximumTotalBytes: Int64 = 512 * 1_024 * 1_024

    private struct ParsedRollout {
        let relativePath: String
        let plan: SessionRolloutPlan
    }

    static func inspect(
        sourceRoot: URL,
        currentCodexHome: URL,
        existingThreadIDs: Set<String>
    ) throws -> V011ExternalSessionImportPreview {
        let source = sourceRoot.standardizedFileURL
        let codexHome = currentCodexHome.standardizedFileURL
        guard !SessionSyncFileSafety.isDescendant(
            source.path,
            of: codexHome.path
        ),
              !SessionSyncFileSafety.isDescendant(
                codexHome.path,
                of: source.path
              ) else {
            throw V011ExternalSessionImportPreflightError
                .sourceOverlapsCurrentCodexHome
        }

        let vaultVerification = SessionVault.looksLikeVault(
            source
        ) ? try SessionVault.verify(
            packageURL: source
        ) : nil

        let files = try SessionSyncFileSafety
            .recursiveJSONLFiles(
                root: source,
                maximumFiles: maximumFiles
            )
        var totalBytes: Int64 = 0
        var parsed: [ParsedRollout] = []
        var issues: [V011ExternalSessionImportIssue] = []

        for file in files {
            try Task.checkCancellation()
            let relativePath = relativePath(
                file,
                root: source
            )
            let fileSize = Int64(
                try file.resourceValues(
                    forKeys: [.fileSizeKey]
                ).fileSize ?? 0
            )
            totalBytes += fileSize
            guard totalBytes <= maximumTotalBytes else {
                throw V011ExternalSessionImportPreflightError
                    .sourceTooLarge
            }
            guard fileSize <= maximumFileBytes else {
                issues.append(
                    V011ExternalSessionImportIssue(
                        relativePath: relativePath,
                        kind: .oversizedFile,
                        detail: "单个会话文件超过64 MB安全上限"
                    )
                )
                continue
            }
            do {
                let archived = relativePath.hasPrefix(
                    "archived_sessions/"
                )
                let plan = try RolloutProviderSynchronizer
                    .inspect(file, archived: archived)
                guard UUID(uuidString: plan.threadID) != nil else {
                    issues.append(
                        V011ExternalSessionImportIssue(
                            relativePath: relativePath,
                            kind: .invalidThreadID,
                            detail: "session_meta中的Thread ID不是标准UUID"
                        )
                    )
                    continue
                }
                guard plan.allThreadIDs.count == 1 else {
                    issues.append(
                        V011ExternalSessionImportIssue(
                            relativePath: relativePath,
                            kind: .invalidRollout,
                            detail: "单个文件包含多个Thread ID，暂不支持导入"
                        )
                    )
                    continue
                }
                parsed.append(
                    ParsedRollout(
                        relativePath: relativePath,
                        plan: plan
                    )
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                issues.append(
                    V011ExternalSessionImportIssue(
                        relativePath: relativePath,
                        kind: .invalidRollout,
                        detail: safeIssueDetail(error)
                    )
                )
            }
        }

        let normalizedExisting = Set(
            existingThreadIDs.map { $0.lowercased() }
        )
        let grouped = Dictionary(
            grouping: parsed,
            by: { $0.plan.threadID.lowercased() }
        )
        var importableCount = 0
        for candidate in parsed {
            let threadID = candidate.plan.threadID.lowercased()
            if (grouped[threadID]?.count ?? 0) > 1 {
                issues.append(
                    V011ExternalSessionImportIssue(
                        relativePath: candidate.relativePath,
                        kind: .duplicateSourceThread,
                        detail: "外部目录中有多个文件使用同一Thread ID"
                    )
                )
            } else if normalizedExisting.contains(threadID) {
                issues.append(
                    V011ExternalSessionImportIssue(
                        relativePath: candidate.relativePath,
                        kind: .existingThreadConflict,
                        detail: "当前Codex已经存在同一Thread ID"
                    )
                )
            } else {
                importableCount += 1
            }
        }

        let orderedIssues = issues.sorted {
            if $0.relativePath == $1.relativePath {
                return $0.kind.rawValue < $1.kind.rawValue
            }
            return $0.relativePath < $1.relativePath
        }
        return V011ExternalSessionImportPreview(
            sourceFolderName: source.lastPathComponent,
            vaultIntegrityVerified:
                vaultVerification != nil,
            vaultActiveSessionCount:
                vaultVerification?.activeFileCount ?? 0,
            vaultArchivedSessionCount:
                vaultVerification?.archivedFileCount ?? 0,
            jsonlFileCount: files.count,
            parsedRolloutCount: parsed.count,
            importableSessionCount: importableCount,
            existingThreadConflictCount: orderedIssues.filter {
                $0.kind == .existingThreadConflict
            }.count,
            duplicateSourceThreadCount: orderedIssues.filter {
                $0.kind == .duplicateSourceThread
            }.count,
            invalidFileCount: orderedIssues.filter {
                $0.kind == .invalidRollout
                    || $0.kind == .invalidThreadID
                    || $0.kind == .oversizedFile
            }.count,
            totalBytes: totalBytes,
            issues: orderedIssues
        )
    }

    private static func relativePath(
        _ file: URL,
        root: URL
    ) -> String {
        let prefix = root.path.hasSuffix("/")
            ? root.path : root.path + "/"
        guard file.path.hasPrefix(prefix) else {
            return file.lastPathComponent
        }
        return String(file.path.dropFirst(prefix.count))
    }

    private static func safeIssueDetail(
        _ error: Error
    ) -> String {
        guard let syncError = error as? SessionSyncError else {
            return "会话文件无法安全读取"
        }
        switch syncError {
        case .noMetadata:
            return "缺少session_meta记录"
        case .conflictingMetadataThreadIDs:
            return "同一文件含无法证明关系的多个Thread ID"
        case .symbolicLink:
            return "文件是符号链接"
        case .unsafePath:
            return "文件不是普通文件"
        default:
            return "会话文件格式无法安全识别"
        }
    }
}
