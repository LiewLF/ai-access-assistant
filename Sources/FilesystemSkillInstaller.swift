import CryptoKit
import Darwin
import Foundation

enum FilesystemSkillInstallerError: LocalizedError, Equatable {
    case wrongPackageType
    case sourceChanged
    case missingSkillManifest
    case unsafeSkillsRoot
    case unsafeTargetName
    case targetAlreadyExists
    case unsafePath(String)
    case installedContentChanged(String)
    case verificationUnavailable

    var errorDescription: String? {
        switch self {
        case .wrongPackageType:
            return "该适配器只允许安装Skill"
        case .sourceChanged:
            return "Skill源码在审查后发生变化，必须重新审查"
        case .missingSkillManifest:
            return "Skill安装包缺少根目录SKILL.md"
        case .unsafeSkillsRoot:
            return "目标Skills目录不是安全的普通目录"
        case .unsafeTargetName:
            return "无法从包ID生成安全Skill目录名"
        case .targetAlreadyExists:
            return "同名Skill目录已存在；禁止覆盖"
        case let .unsafePath(path):
            return "Skill文件路径越界：\(path)"
        case let .installedContentChanged(path):
            return "已安装文件后来发生变化，已保留并转人工处理：\(path)"
        case .verificationUnavailable:
            return "缺少Agent刷新或真实任务验证入口"
        }
    }
}

final class FilesystemSkillComponentAdapter:
    CapabilityComponentAdapter {
    typealias AgentRefresh = () throws -> Void
    typealias RealTaskVerifier = (URL) throws -> Void

    private let inspection: CapabilityLocalInspectionResult
    private let skillsRoot: URL
    private let refreshAgentAction: AgentRefresh
    private let realTaskVerifier: RealTaskVerifier
    private var targetDirectory: URL?

    init(
        inspection: CapabilityLocalInspectionResult,
        skillsRoot: URL,
        refreshAgent: @escaping AgentRefresh,
        verifyRealTask: @escaping RealTaskVerifier
    ) {
        self.inspection = inspection
        self.skillsRoot = skillsRoot.standardizedFileURL
        self.refreshAgentAction = refreshAgent
        self.realTaskVerifier = verifyRealTask
    }

    func createRestorePoint(
        transactionID: String,
        plan: CapabilityInstallationPlan,
        target: CapabilityInstallTarget
    ) throws {
        guard target.packageType == .skill,
              target.executionMode == .filesystemCopy else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        try validateRoot()
        try validateSource(plan: plan)
        let directory = try Self.targetDirectory(
            for: plan.packageID,
            skillsRoot: skillsRoot
        )
        guard !FileManager.default.fileExists(
            atPath: directory.path
        ) else {
            throw FilesystemSkillInstallerError.targetAlreadyExists
        }
        targetDirectory = directory
    }

    func install(
        transactionID: String,
        plan: CapabilityInstallationPlan,
        packageType: CapabilityPackageType,
        target: CapabilityInstallTarget
    ) throws -> CapabilityInstalledManifest {
        guard packageType == .skill,
              target.packageType == .skill else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        try validateSource(plan: plan)
        guard let targetDirectory else {
            throw FilesystemSkillInstallerError.verificationUnavailable
        }
        let manager = FileManager.default
        let staging = skillsRoot.appendingPathComponent(
            ".ai-access-skill-\(transactionID).tmp",
            isDirectory: true
        ).standardizedFileURL
        guard staging.deletingLastPathComponent() == skillsRoot,
              !manager.fileExists(atPath: staging.path),
              !manager.fileExists(atPath: targetDirectory.path) else {
            throw FilesystemSkillInstallerError.targetAlreadyExists
        }
        try manager.createDirectory(
            at: staging,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        var hashes: [String: String] = [:]
        do {
            for relative in plan.expectedFiles.sorted() {
                let source = try safeURL(
                    relative: relative,
                    root: inspection.rootURL
                )
                let destination = try safeURL(
                    relative: relative,
                    root: staging
                )
                let values = try source.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ])
                guard values.isRegularFile == true,
                      values.isSymbolicLink != true else {
                    throw FilesystemSkillInstallerError
                        .unsafePath(relative)
                }
                try manager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                try manager.copyItem(at: source, to: destination)
                let hash = try sha256(destination)
                hashes[relative] = hash
            }
            guard manager.fileExists(
                atPath: staging.appendingPathComponent(
                    "SKILL.md"
                ).path
            ) else {
                throw FilesystemSkillInstallerError
                    .missingSkillManifest
            }
            try manager.moveItem(
                at: staging,
                to: targetDirectory
            )
        } catch {
            if manager.fileExists(atPath: staging.path) {
                try? manager.removeItem(at: staging)
            }
            throw error
        }
        let createdPaths = hashes.keys.sorted().map {
            targetDirectory.appendingPathComponent($0).path
        }
        let absoluteHashes = Dictionary(
            uniqueKeysWithValues: hashes.map {
                (targetDirectory.appendingPathComponent($0.key).path, $0.value)
            }
        )
        return CapabilityInstalledManifest(
            schemaVersion: 2,
            transactionID: transactionID,
            planID: plan.id,
            packageID: plan.packageID,
            packageType: .skill,
            createdPaths: createdPaths,
            modifiedPaths: [],
            preservedUserDataPaths: [],
            installedAt: Date(),
            verifiedAt: nil,
            createdFileSHA256: absoluteHashes
        )
    }

    func refreshAgent(
        packageType: CapabilityPackageType
    ) throws {
        guard packageType == .skill else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        try refreshAgentAction()
    }

    func verifyCapability(
        packageType: CapabilityPackageType,
        manifest: CapabilityInstalledManifest
    ) throws {
        guard packageType == .skill,
              let targetDirectory else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        guard let hashes = manifest.createdFileSHA256,
              !hashes.isEmpty else {
            throw FilesystemSkillInstallerError
                .verificationUnavailable
        }
        for (path, expected) in hashes {
            let url = URL(fileURLWithPath: path)
            guard try sha256(url) == expected else {
                throw FilesystemSkillInstallerError
                    .installedContentChanged(path)
            }
        }
        try realTaskVerifier(targetDirectory)
    }

    func rollback(
        transactionID: String,
        manifest: CapabilityInstalledManifest?
    ) throws {
        if let manifest {
            try removeCreatedFiles(manifest)
            return
        }
        if let targetDirectory,
           FileManager.default.fileExists(
               atPath: targetDirectory.path
           ) {
            try removeEmptyDirectoryTree(
                from: targetDirectory
            )
        }
    }

    func uninstall(
        manifest: CapabilityInstalledManifest
    ) throws {
        guard manifest.packageType == .skill else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        try Self.uninstall(
            manifest: manifest,
            skillsRoot: skillsRoot
        )
    }

    private func validateRoot() throws {
        let values = try skillsRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw FilesystemSkillInstallerError.unsafeSkillsRoot
        }
    }

    private func validateSource(
        plan: CapabilityInstallationPlan
    ) throws {
        guard plan.expectedFiles.contains("SKILL.md") else {
            throw FilesystemSkillInstallerError
                .missingSkillManifest
        }
        let current = try CapabilityLocalPackageInspector.inspect(
            root: inspection.rootURL
        )
        guard current.treeSHA256 == inspection.treeSHA256,
              plan.pinnedVersion
                == "tree-sha256:\(inspection.treeSHA256)",
              Set(plan.expectedFiles)
                == Set(inspection.relativeFiles) else {
            throw FilesystemSkillInstallerError.sourceChanged
        }
    }

    static func targetDirectory(
        for packageID: String,
        skillsRoot: URL
    ) throws -> URL {
        let normalizedRoot = skillsRoot.standardizedFileURL
        let candidate = packageID.split(separator: "/").last
            .map(String.init) ?? packageID
        let safe = candidate.filter {
            $0.isLetter || $0.isNumber
                || $0 == "-" || $0 == "_" || $0 == "."
        }
        guard !safe.isEmpty,
              safe != ".",
              safe != ".." else {
            throw FilesystemSkillInstallerError.unsafeTargetName
        }
        let destination = normalizedRoot.appendingPathComponent(
            String(safe.prefix(120)),
            isDirectory: true
        ).standardizedFileURL
        guard destination.deletingLastPathComponent().path
            == normalizedRoot.path else {
            throw FilesystemSkillInstallerError.unsafeTargetName
        }
        return destination
    }

    private func safeURL(
        relative: String,
        root: URL
    ) throws -> URL {
        guard !relative.isEmpty,
              !relative.hasPrefix("/"),
              !relative.split(separator: "/")
                .contains("..") else {
            throw FilesystemSkillInstallerError
                .unsafePath(relative)
        }
        let url = root.appendingPathComponent(
            relative
        ).standardizedFileURL
        guard url.path.hasPrefix(
            root.standardizedFileURL.path + "/"
        ) else {
            throw FilesystemSkillInstallerError
                .unsafePath(relative)
        }
        return url
    }

    private func removeCreatedFiles(
        _ manifest: CapabilityInstalledManifest
    ) throws {
        try Self.removeCreatedFiles(
            manifest,
            skillsRoot: skillsRoot,
            targetDirectory: targetDirectory
        )
    }

    static func uninstall(
        manifest: CapabilityInstalledManifest,
        skillsRoot: URL
    ) throws {
        guard manifest.packageType == .skill else {
            throw FilesystemSkillInstallerError.wrongPackageType
        }
        let target = try Self.targetDirectory(
            for: manifest.packageID,
            skillsRoot: skillsRoot
        )
        try removeCreatedFiles(
            manifest,
            skillsRoot: skillsRoot.standardizedFileURL,
            targetDirectory: target
        )
    }

    private static func removeCreatedFiles(
        _ manifest: CapabilityInstalledManifest,
        skillsRoot: URL,
        targetDirectory: URL?
    ) throws {
        let normalizedRoot = skillsRoot.standardizedFileURL
        let expectedTarget = try Self.targetDirectory(
            for: manifest.packageID,
            skillsRoot: normalizedRoot
        )
        if let targetDirectory,
           targetDirectory.standardizedFileURL != expectedTarget {
            throw FilesystemSkillInstallerError
                .unsafePath(targetDirectory.path)
        }
        let hashes = manifest.createdFileSHA256 ?? [:]
        var files: [URL] = []
        for path in manifest.createdPaths.reversed() {
            let url = URL(fileURLWithPath: path)
                .standardizedFileURL
            guard url.path.hasPrefix(expectedTarget.path + "/"),
                  !url.path.contains("/../") else {
                throw FilesystemSkillInstallerError
                    .unsafePath(path)
            }
            guard FileManager.default.fileExists(
               atPath: url.path
            ) else { continue }
            guard let expected = hashes[path],
                  try sha256File(url) == expected else {
                throw FilesystemSkillInstallerError
                    .installedContentChanged(path)
            }
            files.append(url)
        }
        for url in files {
            try FileManager.default.removeItem(at: url)
        }
        try removeEmptyDirectoryTree(
            from: expectedTarget,
            skillsRoot: normalizedRoot
        )
    }

    private func removeEmptyDirectoryTree(
        from start: URL
    ) throws {
        try Self.removeEmptyDirectoryTree(
            from: start,
            skillsRoot: skillsRoot
        )
    }

    private static func removeEmptyDirectoryTree(
        from start: URL,
        skillsRoot: URL
    ) throws {
        guard FileManager.default.fileExists(
            atPath: start.path
        ) else { return }
        var directory = start.standardizedFileURL
        while directory != skillsRoot,
              directory.path.hasPrefix(
                  skillsRoot.path + "/"
              ) {
            let children = try FileManager.default
                .contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil
                )
            guard children.isEmpty else { return }
            try FileManager.default.removeItem(at: directory)
            directory = directory
                .deletingLastPathComponent()
        }
    }

    private func sha256(_ url: URL) throws -> String {
        try Self.sha256File(url)
    }

    private static func sha256File(
        _ url: URL
    ) throws -> String {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= 5 * 1_024 * 1_024 else {
            throw FilesystemSkillInstallerError
                .unsafePath(url.path)
        }
        let data = try Data(
            contentsOf: url,
            options: .mappedIfSafe
        )
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }
}

enum LocalSkillManagementError: LocalizedError {
    case unsafeManifestStore
    case invalidManifest(String)
    case duplicateTransaction(String)
    case manifestNotFound(String)
    case manifestStoreChanged
    case committedManifestMissing
    case manifestPersistenceFailed(
        CapabilityInstalledManifest,
        String
    )
    case uninstallReceiptPersistenceFailed(
        CapabilityInstalledManifest,
        String
    )

    var errorDescription: String? {
        switch self {
        case .unsafeManifestStore:
            return "Skill安装回执目录不安全"
        case let .invalidManifest(reason):
            return "Skill安装回执无效：\(reason)"
        case let .duplicateTransaction(id):
            return "Skill安装事务重复：\(id)"
        case let .manifestNotFound(id):
            return "没有找到Skill安装回执：\(id)"
        case .manifestStoreChanged:
            return "Skill安装回执已被其他进程修改；已停止覆盖"
        case .committedManifestMissing:
            return "Skill安装事务已提交但缺少文件清单"
        case let .manifestPersistenceFailed(manifest, reason):
            return "Skill已安装，但回执保存失败；未自动回滚。事务\(manifest.transactionID)：\(reason)"
        case let .uninstallReceiptPersistenceFailed(manifest, reason):
            return "Skill文件已按回执卸载，但回执更新失败；请重新检查。事务\(manifest.transactionID)：\(reason)"
        }
    }
}

private struct LocalSkillManifestDocument: Codable {
    let schemaVersion: Int
    let manifests: [CapabilityInstalledManifest]
}

struct LocalSkillManifestSnapshot {
    let manifests: [CapabilityInstalledManifest]
    let fileSHA256: String?
}

struct LocalSkillManifestStore {
    private static let schemaVersion = 1
    private static let maximumBytes = 2 * 1_024 * 1_024

    let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
    }

    func load(
        skillsRoot: URL
    ) throws -> [CapabilityInstalledManifest] {
        try snapshot(skillsRoot: skillsRoot).manifests
    }

    func snapshot(
        skillsRoot: URL
    ) throws -> LocalSkillManifestSnapshot {
        guard FileManager.default.fileExists(
            atPath: fileURL.path
        ) else {
            return LocalSkillManifestSnapshot(
                manifests: [],
                fileSHA256: nil
            )
        }
        let data = try validatedData()
        let document: LocalSkillManifestDocument
        do {
            document = try JSONDecoder().decode(
                LocalSkillManifestDocument.self,
                from: data
            )
        } catch {
            throw LocalSkillManagementError
                .invalidManifest("JSON无法解码")
        }
        guard document.schemaVersion == Self.schemaVersion else {
            throw LocalSkillManagementError
                .invalidManifest("Schema版本不支持")
        }
        try validate(
            document.manifests,
            skillsRoot: skillsRoot
        )
        return LocalSkillManifestSnapshot(
            manifests: document.manifests,
            fileSHA256: Self.sha256(data)
        )
    }

    func save(
        _ manifests: [CapabilityInstalledManifest],
        skillsRoot: URL,
        expectedCurrentSHA256: String?
    ) throws {
        try validate(manifests, skillsRoot: skillsRoot)
        try ensureSafeDirectory(
            fileURL.deletingLastPathComponent()
        )
        let actualSHA256: String?
        if FileManager.default.fileExists(atPath: fileURL.path) {
            actualSHA256 = Self.sha256(try validatedData())
        } else {
            actualSHA256 = nil
        }
        guard actualSHA256 == expectedCurrentSHA256 else {
            throw LocalSkillManagementError.manifestStoreChanged
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            LocalSkillManifestDocument(
                schemaVersion: Self.schemaVersion,
                manifests: manifests.sorted {
                    $0.transactionID < $1.transactionID
                }
            )
        )
        try atomicWrite(
            data,
            expectedCurrentSHA256: expectedCurrentSHA256
        )
        let written = try validatedData()
        guard Self.sha256(written) == Self.sha256(data) else {
            throw LocalSkillManagementError
                .invalidManifest("写后hash不一致")
        }
    }

    private func validatedData() throws -> Data {
        let values = try fileURL.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              (values.fileSize ?? 0) <= Self.maximumBytes else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        let attributes = try FileManager.default.attributesOfItem(
            atPath: fileURL.path
        )
        let mode = (attributes[.posixPermissions] as? NSNumber)?
            .intValue ?? -1
        guard mode >= 0, mode & 0o077 == 0 else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        return try Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    private func validate(
        _ manifests: [CapabilityInstalledManifest],
        skillsRoot: URL
    ) throws {
        let identifiers = manifests.map(\.transactionID)
        guard Set(identifiers).count == identifiers.count else {
            throw LocalSkillManagementError
                .invalidManifest("事务ID重复")
        }
        for manifest in manifests {
            guard manifest.schemaVersion == 2,
                  manifest.packageType == .skill,
                  !manifest.transactionID.isEmpty,
                  !manifest.planID.isEmpty,
                  !manifest.packageID.isEmpty,
                  !manifest.createdPaths.isEmpty,
                  Set(manifest.createdPaths).count
                    == manifest.createdPaths.count,
                  manifest.modifiedPaths.isEmpty,
                  let hashes = manifest.createdFileSHA256,
                  Set(hashes.keys) == Set(manifest.createdPaths) else {
                throw LocalSkillManagementError
                    .invalidManifest("字段或文件hash清单不完整")
            }
            let target = try FilesystemSkillComponentAdapter
                .targetDirectory(
                    for: manifest.packageID,
                    skillsRoot: skillsRoot
                )
            for path in manifest.createdPaths {
                let url = URL(fileURLWithPath: path)
                    .standardizedFileURL
                guard url.path.hasPrefix(target.path + "/"),
                      !url.path.contains("/../"),
                      hashes[path].map(Self.isSHA256) == true else {
                    throw LocalSkillManagementError
                        .invalidManifest("文件路径或hash越界")
                }
            }
        }
    }

    private func ensureSafeDirectory(
        _ directory: URL
    ) throws {
        let manager = FileManager.default
        let normalized = directory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        var missing: [URL] = []
        var cursor = normalized
        while !manager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else {
                throw LocalSkillManagementError
                    .unsafeManifestStore
            }
            cursor = parent
        }
        let ancestorValues = try cursor.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard ancestorValues.isDirectory == true,
              ancestorValues.isSymbolicLink != true else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        for missingDirectory in missing.reversed() {
            try manager.createDirectory(
                at: missingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try normalized.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        try manager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: normalized.path
        )
    }

    private func atomicWrite(
        _ data: Data,
        expectedCurrentSHA256: String?
    ) throws {
        let manager = FileManager.default
        let temporary = fileURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".ai-access-skill-receipt-\(UUID().uuidString).tmp"
            )
        let descriptor = open(
            temporary.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            mode_t(0o600)
        )
        guard descriptor >= 0 else {
            throw LocalSkillManagementError
                .unsafeManifestStore
        }
        var removeTemporary = true
        defer {
            _ = close(descriptor)
            if removeTemporary {
                try? manager.removeItem(at: temporary)
            }
        }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    throw LocalSkillManagementError
                        .unsafeManifestStore
                }
                offset += count
            }
        }
        guard fchmod(descriptor, mode_t(0o600)) == 0,
              fsync(descriptor) == 0 else {
            throw LocalSkillManagementError
                .unsafeManifestStore
        }
        let currentSHA256: String?
        if manager.fileExists(atPath: fileURL.path) {
            currentSHA256 = Self.sha256(try validatedData())
        } else {
            currentSHA256 = nil
        }
        guard currentSHA256 == expectedCurrentSHA256 else {
            throw LocalSkillManagementError.manifestStoreChanged
        }
        guard rename(temporary.path, fileURL.path) == 0 else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        removeTemporary = false
        guard chmod(fileURL.path, mode_t(0o600)) == 0 else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        let directoryDescriptor = open(
            fileURL.deletingLastPathComponent().path,
            O_RDONLY | O_CLOEXEC
        )
        guard directoryDescriptor >= 0 else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        defer { _ = close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private static func isSHA256(_ value: String) -> Bool {
        value.count == 64 && value.utf8.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }
}

final class LocalSkillManagementService {
    typealias AgentRefresh = () throws -> Void
    typealias InstalledSkillVerifier = (URL) throws -> Void

    let skillsRoot: URL
    private let manifestStore: LocalSkillManifestStore
    private let refreshAgentAction: AgentRefresh
    private let installedSkillVerifier: InstalledSkillVerifier

    init(
        skillsRoot: URL,
        manifestStoreURL: URL,
        refreshAgent: @escaping AgentRefresh = {},
        verifyInstalledSkill:
            @escaping InstalledSkillVerifier = { _ in }
    ) throws {
        self.skillsRoot = skillsRoot
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let storeURL = manifestStoreURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard !storeURL.path.hasPrefix(
            self.skillsRoot.path + "/"
        ) else {
            throw LocalSkillManagementError.unsafeManifestStore
        }
        manifestStore = LocalSkillManifestStore(
            fileURL: storeURL
        )
        refreshAgentAction = refreshAgent
        installedSkillVerifier = verifyInstalledSkill
    }

    func targetDirectory(
        for packageID: String
    ) throws -> URL {
        try FilesystemSkillComponentAdapter.targetDirectory(
            for: packageID,
            skillsRoot: skillsRoot
        )
    }

    func installedManifests()
        throws -> [CapabilityInstalledManifest] {
        try manifestStore.load(skillsRoot: skillsRoot)
    }

    func install(
        plan: CapabilityInstallationPlan,
        inspection: CapabilityLocalInspectionResult,
        userConfirmed: Bool,
        transactionID: String = UUID().uuidString,
        now: Date = Date()
    ) throws -> CapabilityComponentTransaction {
        guard userConfirmed else {
            throw CapabilityComponentTransactionError
                .authorizationMissing
        }
        guard inspection.review.riskLevel != .high,
              inspection.review.riskLevel != .unknown else {
            throw CapabilityComponentTransactionError
                .highRiskBlocked
        }
        guard plan.expectedFiles.contains("SKILL.md"),
              plan.pinnedVersion
                == "tree-sha256:\(inspection.treeSHA256)",
              Set(plan.expectedFiles)
                == Set(inspection.relativeFiles) else {
            throw FilesystemSkillInstallerError.sourceChanged
        }
        try ensureSkillsRoot()
        var snapshot = try manifestStore.snapshot(
            skillsRoot: skillsRoot
        )
        guard !snapshot.manifests.contains(where: {
            $0.transactionID == transactionID
        }) else {
            throw LocalSkillManagementError
                .duplicateTransaction(transactionID)
        }
        try manifestStore.save(
            snapshot.manifests,
            skillsRoot: skillsRoot,
            expectedCurrentSHA256: snapshot.fileSHA256
        )
        snapshot = try manifestStore.snapshot(
            skillsRoot: skillsRoot
        )
        let adapter = FilesystemSkillComponentAdapter(
            inspection: inspection,
            skillsRoot: skillsRoot,
            refreshAgent: refreshAgentAction,
            verifyRealTask: { [installedSkillVerifier] root in
                let installed = try CapabilityLocalPackageInspector
                    .inspect(root: root)
                guard installed.treeSHA256
                        == inspection.treeSHA256 else {
                    throw FilesystemSkillInstallerError
                        .sourceChanged
                }
                try installedSkillVerifier(root)
            }
        )
        let target = CapabilityInstallTargetResolver.target(
            type: .skill
        )
        let authorization = CapabilityInstallAuthorization(
            planID: plan.id,
            packageID: plan.packageID,
            approvedTarget: target,
            approvedFiles: plan.expectedFiles,
            approvedCommands: plan.commands,
            approvedAt: now,
            userConfirmed: true
        )
        let transaction = try CapabilityComponentTransactionEngine
            .execute(
                plan: plan,
                packageType: .skill,
                review: inspection.review,
                authorization: authorization,
                adapter: adapter,
                transactionID: transactionID,
                now: now
            )
        guard let manifest = transaction.manifest else {
            throw LocalSkillManagementError
                .committedManifestMissing
        }
        do {
            try manifestStore.save(
                snapshot.manifests + [manifest],
                skillsRoot: skillsRoot,
                expectedCurrentSHA256: snapshot.fileSHA256
            )
        } catch {
            throw LocalSkillManagementError
                .manifestPersistenceFailed(
                    manifest,
                    error.localizedDescription
                )
        }
        return transaction
    }

    func uninstall(
        transactionID: String
    ) throws {
        let snapshot = try manifestStore.snapshot(
            skillsRoot: skillsRoot
        )
        guard let manifest = snapshot.manifests.first(where: {
            $0.transactionID == transactionID
        }) else {
            throw LocalSkillManagementError
                .manifestNotFound(transactionID)
        }
        try FilesystemSkillComponentAdapter.uninstall(
            manifest: manifest,
            skillsRoot: skillsRoot
        )
        do {
            try manifestStore.save(
                snapshot.manifests.filter {
                    $0.transactionID != transactionID
                },
                skillsRoot: skillsRoot,
                expectedCurrentSHA256: snapshot.fileSHA256
            )
        } catch {
            throw LocalSkillManagementError
                .uninstallReceiptPersistenceFailed(
                    manifest,
                    error.localizedDescription
                )
        }
    }

    private func ensureSkillsRoot() throws {
        let manager = FileManager.default
        var missing: [URL] = []
        var cursor = skillsRoot
        while !manager.fileExists(atPath: cursor.path) {
            missing.append(cursor)
            let parent = cursor.deletingLastPathComponent()
            guard parent != cursor else {
                throw FilesystemSkillInstallerError
                    .unsafeSkillsRoot
            }
            cursor = parent
        }
        let ancestorValues = try cursor.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard ancestorValues.isDirectory == true,
              ancestorValues.isSymbolicLink != true else {
            throw FilesystemSkillInstallerError.unsafeSkillsRoot
        }
        for missingDirectory in missing.reversed() {
            try manager.createDirectory(
                at: missingDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let values = try skillsRoot.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw FilesystemSkillInstallerError.unsafeSkillsRoot
        }
    }
}
