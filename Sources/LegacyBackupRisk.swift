import Foundation

enum LegacyBackupRiskError: LocalizedError {
    case unsafeDirectory
    case tooManyFiles
    case fileTooLarge
    case totalTooLarge
    case changedAfterScan
    case noRiskFiles

    var errorDescription: String? {
        switch self {
        case .unsafeDirectory:
            return "只允许扫描当前用户目录内明确选择的provider-switch-backups普通目录"
        case .tooManyFiles:
            return "备份文件超过1000个，已停止扫描"
        case .fileTooLarge:
            return "单个备份超过2 MB，已停止扫描"
        case .totalTooLarge:
            return "备份总读取量超过50 MB，已停止扫描"
        case .changedAfterScan:
            return "备份在扫描后发生变化，未创建归档"
        case .noRiskFiles:
            return "没有发现需要加密归档的疑似明文备份"
        }
    }
}

struct LegacyBackupRiskFile: Equatable {
    let url: URL
    let relativePath: String
    let fileHash: String
    let byteCount: Int
    let modifiedAt: Date?
    let permissions: Int
}

struct LegacyBackupRiskReport: Equatable {
    let scannedFileCount: Int
    let scannedByteCount: Int
    let riskFileCount: Int
    let earliestModifiedAt: Date?
    let latestModifiedAt: Date?
    let riskFiles: [LegacyBackupRiskFile]

    var plaintextRiskRemains: Bool {
        riskFileCount > 0
    }
}

struct LegacyBackupArchiveReceipt: Equatable {
    let snapshot: SnapshotManifest
    let archivedFileCount: Int
    let originalFilesRetained: Bool
}

struct LegacyBackupRiskScanner {
    let allowedRoot: URL

    func scan(directory: URL) throws -> LegacyBackupRiskReport {
        let root = allowedRoot.standardizedFileURL.path
        let selected = directory.standardizedFileURL
        guard selected.lastPathComponent == "provider-switch-backups",
              selected.path.hasPrefix(root + "/"),
              let directoryValues = try? selected.resourceValues(
                  forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
              ),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true else {
            throw LegacyBackupRiskError.unsafeDirectory
        }
        guard let enumerator = FileManager.default.enumerator(
            at: selected,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .isSymbolicLinkKey,
                .fileSizeKey,
                .contentModificationDateKey,
            ],
            options: [.skipsPackageDescendants]
        ) else {
            throw LegacyBackupRiskError.unsafeDirectory
        }

        var scannedCount = 0
        var scannedBytes = 0
        var riskFiles: [LegacyBackupRiskFile] = []
        var dates: [Date] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(
                forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                    .fileSizeKey,
                    .contentModificationDateKey,
                ]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            scannedCount += 1
            guard scannedCount <= 1_000 else {
                throw LegacyBackupRiskError.tooManyFiles
            }
            let size = values.fileSize ?? 0
            guard size <= 2 * 1_024 * 1_024 else {
                throw LegacyBackupRiskError.fileTooLarge
            }
            scannedBytes += size
            guard scannedBytes <= 50 * 1_024 * 1_024 else {
                throw LegacyBackupRiskError.totalTooLarge
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            if let modifiedAt = values.contentModificationDate {
                dates.append(modifiedAt)
            }
            guard Self.containsSuspectedPlaintextCredential(data) else {
                continue
            }
            let relative = String(
                url.path.dropFirst(selected.path.count)
            ).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let attributes = try FileManager.default.attributesOfItem(
                atPath: url.path
            )
            riskFiles.append(
                LegacyBackupRiskFile(
                    url: url,
                    relativePath: relative,
                    fileHash: SecureProfileVault.sha256(data),
                    byteCount: data.count,
                    modifiedAt: values.contentModificationDate,
                    permissions:
                        attributes[.posixPermissions] as? Int ?? 0o600
                )
            )
        }
        return LegacyBackupRiskReport(
            scannedFileCount: scannedCount,
            scannedByteCount: scannedBytes,
            riskFileCount: riskFiles.count,
            earliestModifiedAt: dates.min(),
            latestModifiedAt: dates.max(),
            riskFiles: riskFiles
        )
    }

    func archive(
        report: LegacyBackupRiskReport,
        vault: SecureProfileVault
    ) throws -> LegacyBackupArchiveReceipt {
        guard !report.riskFiles.isEmpty else {
            throw LegacyBackupRiskError.noRiskFiles
        }
        var inputs: [SnapshotInput] = []
        for file in report.riskFiles {
            let data = try Data(contentsOf: file.url)
            guard SecureProfileVault.sha256(data) == file.fileHash else {
                throw LegacyBackupRiskError.changedAfterScan
            }
            let opaqueName = SecureProfileVault.sha256(
                Data(file.relativePath.utf8)
            )
            inputs.append(
                SnapshotInput(
                    relativePath: "legacy-backups/\(opaqueName).bin",
                    data: data,
                    permissions: file.permissions
                )
            )
        }
        let snapshot = try vault.saveSnapshot(
            profileID: "legacy-provider-backups",
            adapterVersion: AppReleaseMetadata.version,
            inputs: inputs
        )
        return LegacyBackupArchiveReceipt(
            snapshot: snapshot,
            archivedFileCount: inputs.count,
            originalFilesRetained: true
        )
    }

    private static func containsSuspectedPlaintextCredential(
        _ data: Data
    ) -> Bool {
        let text = String(decoding: data, as: UTF8.self)
        let lower = text.lowercased()
        if [
            "experimental_bearer_token",
            "authorization",
            "api_key",
            "api-key",
            "bearer ",
        ].contains(where: lower.contains) {
            return true
        }
        return text.range(
            of: #"sk-[A-Za-z0-9_-]{16,}"#,
            options: .regularExpression
        ) != nil
    }
}
