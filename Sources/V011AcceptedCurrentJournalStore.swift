// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

extension V011SwitchJournalStore {
    func commitAcceptedCurrent(
        _ journal: V011SwitchJournal,
        expectedJournalHash: String
    ) throws -> V011SwitchJournal {
        guard journal.phase == .acceptedCurrent,
              journal.acceptedCurrent != nil else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withJournalLock { rootDescriptor in
            let sourceLeaf = "\(journal.id).json"
            guard let originalData = try regularFileData(
                    directoryDescriptor: rootDescriptor,
                    leaf: sourceLeaf,
                    requiredPermissions: 0o600
                  ),
                  TOMLSemanticEngine.sha256(originalData)
                    == expectedJournalHash else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }

            let acceptedData = try encoded(journal)
            let acceptedHash = TOMLSemanticEngine.sha256(
                acceptedData
            )
            let persisted = try decoded(
                acceptedData,
                expectedID: journal.id
            )
            let destinationLeaf =
                "\(journal.id)-accepted.json"
            let source = journalURL(journal.id)
            let archiveDescriptor = try openArchiveDescriptor(
                rootDescriptor: rootDescriptor
            )
            defer { _ = Darwin.close(archiveDescriptor) }

            var sourceMetadata = stat()
            var archiveMetadata = stat()
            guard rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ),
                  Darwin.fstat(
                    archiveDescriptor,
                    &archiveMetadata
                  ) == 0,
                  archiveMetadata.st_mode & S_IFMT == S_IFDIR,
                  Darwin.fstatat(
                    rootDescriptor,
                    sourceLeaf,
                    &sourceMetadata,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sourceMetadata.st_mode & S_IFMT == S_IFREG,
                  sourceMetadata.st_dev
                    == archiveMetadata.st_dev else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "恢复事务目录身份无法确认，已禁止继续提交"
                )
            }

            do {
                try preserveRawRecordPreimage(
                    originalData,
                    for: source
                )
                try SessionSyncAtomicFile.write(
                    acceptedData,
                    to: source,
                    expectedHash: expectedJournalHash,
                    permissions: 0o600,
                    modificationDate: nil
                )
                guard rootDescriptorMatchesCanonicalPath(
                        rootDescriptor
                      ),
                      archiveDescriptorMatchesRootEntry(
                        rootDescriptor: rootDescriptor,
                        archiveDescriptor: archiveDescriptor
                      ),
                      try hashRegularFile(
                        directoryDescriptor: rootDescriptor,
                        leaf: sourceLeaf,
                        requiredPermissions: 0o600
                      ) == acceptedHash else {
                    throw V011AcceptedJournalCommitIndeterminate(
                        detail: "accepted恢复记录未写入已锁定目录"
                    )
                }
                try faultInjector(
                    .afterAcceptedJournalWrite
                )
            } catch let error as
                V011AcceptedJournalCommitIndeterminate {
                throw error
            } catch {
                let primary = error
                try restoreOriginalJournal(
                    originalData,
                    rootDescriptor: rootDescriptor,
                    sourceLeaf: sourceLeaf,
                    originalHash: expectedJournalHash,
                    acceptedHash: acceptedHash
                )
                throw primary
            }

            do {
                try faultInjector(
                    .beforeExclusiveArchiveRename
                )
                guard rootDescriptorMatchesCanonicalPath(
                        rootDescriptor
                      ),
                      archiveDescriptorMatchesRootEntry(
                        rootDescriptor: rootDescriptor,
                        archiveDescriptor: archiveDescriptor
                      ),
                      try hashRegularFile(
                        directoryDescriptor: rootDescriptor,
                        leaf: sourceLeaf,
                        requiredPermissions: 0o600
                      ) == acceptedHash,
                      Darwin.renameatx_np(
                        rootDescriptor,
                        sourceLeaf,
                        archiveDescriptor,
                        destinationLeaf,
                        UInt32(RENAME_EXCL)
                      ) == 0 else {
                    throw V011SwitchError
                        .invalidRecoveryJournal
                }
            } catch {
                let primary = error
                do {
                    try restoreOriginalJournal(
                        originalData,
                        rootDescriptor: rootDescriptor,
                        sourceLeaf: sourceLeaf,
                        originalHash: expectedJournalHash,
                        acceptedHash: acceptedHash
                    )
                } catch {
                    throw V011AcceptedJournalCommitIndeterminate(
                        detail: "旧恢复事务归档失败，原记录补偿状态无法确认"
                    )
                }
                throw primary
            }

            guard rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ),
                  try hashRegularFile(
                    directoryDescriptor: rootDescriptor,
                    leaf: sourceLeaf,
                    requiredPermissions: nil
                  ) == nil,
                  try hashRegularFile(
                    directoryDescriptor: archiveDescriptor,
                    leaf: destinationLeaf,
                    requiredPermissions: 0o600
                  ) == acceptedHash,
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ) else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "accepted恢复记录归档后核对失败"
                )
            }
            let archiveSync = directorySynchronizer(
                archiveDescriptor
            )
            let rootSync = directorySynchronizer(
                rootDescriptor
            )
            guard archiveSync == 0,
                  rootSync == 0,
                  rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ) else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "旧恢复事务已移入归档，但目录持久化状态无法确认"
                )
            }
            return persisted
        }
    }

    func archivePendingKeepingCurrent(
        _ journal: V011SwitchJournal,
        expectedJournalHash: String
    ) throws -> V011SwitchJournal {
        guard journal.phase.isPending else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return try withJournalLock { rootDescriptor in
            let sourceLeaf = "\(journal.id).json"
            guard let originalData = try regularFileData(
                    directoryDescriptor: rootDescriptor,
                    leaf: sourceLeaf,
                    requiredPermissions: 0o600
                  ),
                  TOMLSemanticEngine.sha256(originalData)
                    == expectedJournalHash else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }
            let persisted = try decoded(
                originalData,
                expectedID: journal.id
            )
            guard persisted == journal,
                  persisted.phase.isPending else {
                throw V011SwitchError
                    .concurrentConfigurationChange
            }

            let destinationLeaf =
                "\(journal.id)-kept-current.json"
            let archiveDescriptor = try openArchiveDescriptor(
                rootDescriptor: rootDescriptor
            )
            defer { _ = Darwin.close(archiveDescriptor) }
            var sourceMetadata = stat()
            var archiveMetadata = stat()
            guard rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ),
                  Darwin.fstat(
                    archiveDescriptor,
                    &archiveMetadata
                  ) == 0,
                  archiveMetadata.st_mode & S_IFMT == S_IFDIR,
                  Darwin.fstatat(
                    rootDescriptor,
                    sourceLeaf,
                    &sourceMetadata,
                    AT_SYMLINK_NOFOLLOW
                  ) == 0,
                  sourceMetadata.st_mode & S_IFMT == S_IFREG,
                  sourceMetadata.st_mode & 0o777 == 0o600,
                  sourceMetadata.st_dev
                    == archiveMetadata.st_dev,
                  Darwin.renameatx_np(
                    rootDescriptor,
                    sourceLeaf,
                    archiveDescriptor,
                    destinationLeaf,
                    UInt32(RENAME_EXCL)
                  ) == 0 else {
                throw V011SwitchError.invalidRecoveryJournal
            }

            guard rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ),
                  try hashRegularFile(
                    directoryDescriptor: rootDescriptor,
                    leaf: sourceLeaf,
                    requiredPermissions: nil
                  ) == nil,
                  try hashRegularFile(
                    directoryDescriptor: archiveDescriptor,
                    leaf: destinationLeaf,
                    requiredPermissions: 0o600
                  ) == expectedJournalHash else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "旧恢复事务归档后核对失败"
                )
            }
            guard directorySynchronizer(archiveDescriptor) == 0,
                  directorySynchronizer(rootDescriptor) == 0,
                  rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  archiveDescriptorMatchesRootEntry(
                    rootDescriptor: rootDescriptor,
                    archiveDescriptor: archiveDescriptor
                  ) else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "旧恢复事务已归档，但目录持久化状态无法确认"
                )
            }
            return persisted
        }
    }

    private func restoreOriginalJournal(
        _ originalData: Data,
        rootDescriptor: Int32,
        sourceLeaf: String,
        originalHash: String,
        acceptedHash: String
    ) throws {
        guard rootDescriptorMatchesCanonicalPath(
            rootDescriptor
        ) else {
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "恢复事务目录在补偿前发生变化"
            )
        }
        let currentHash = try hashRegularFile(
            directoryDescriptor: rootDescriptor,
            leaf: sourceLeaf,
            requiredPermissions: nil
        )
        switch classifyAtomicWrite(
            currentHash: currentHash,
            originalHash: originalHash,
            intendedHash: acceptedHash
        ) {
        case .original:
            try verifyOriginalJournal(
                rootDescriptor: rootDescriptor,
                sourceLeaf: sourceLeaf,
                originalHash: originalHash
            )
            return
        case .foreign:
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "旧恢复事务记录已被并发修改，禁止自动补偿"
            )
        case .intended:
            break
        }
        let source = rootURL.appendingPathComponent(sourceLeaf)
        do {
            let acceptedData = try regularFileData(
                directoryDescriptor: rootDescriptor,
                leaf: sourceLeaf,
                requiredPermissions: nil
            )
            guard let acceptedData,
                  TOMLSemanticEngine.sha256(acceptedData)
                    == acceptedHash else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "旧恢复事务记录无法在补偿前保全"
                )
            }
            try preserveRawRecordPreimage(
                acceptedData,
                for: source
            )
            try SessionSyncAtomicFile.write(
                originalData,
                to: source,
                expectedHash: acceptedHash,
                permissions: 0o600,
                modificationDate: nil
            )
        } catch {
            guard rootDescriptorMatchesCanonicalPath(
                    rootDescriptor
                  ),
                  classifyAtomicWrite(
                currentHash: try hashRegularFile(
                    directoryDescriptor: rootDescriptor,
                    leaf: sourceLeaf,
                    requiredPermissions: nil
                ),
                originalHash: originalHash,
                intendedHash: acceptedHash
            ) == .original else {
                throw error
            }
        }
        try verifyOriginalJournal(
            rootDescriptor: rootDescriptor,
            sourceLeaf: sourceLeaf,
            originalHash: originalHash
        )
    }

    func withOriginalJournalAndNoAcceptedArchive<T>(
        journalID: String,
        expectedJournalHash: String,
        _ body: () throws -> T
    ) throws -> T {
        try withJournalLock { rootDescriptor in
            guard try originalJournalAndAcceptedArchiveAbsent(
                rootDescriptor: rootDescriptor,
                journalID: journalID,
                expectedJournalHash: expectedJournalHash
            ) else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "无法证明旧恢复事务仍为原记录且不存在accepted归档"
                )
            }
            let result = try body()
            guard try originalJournalAndAcceptedArchiveAbsent(
                rootDescriptor: rootDescriptor,
                journalID: journalID,
                expectedJournalHash: expectedJournalHash
            ) else {
                throw V011AcceptedJournalCommitIndeterminate(
                    detail: "state补偿后旧恢复事务状态发生变化"
                )
            }
            return result
        }
    }

    private func verifyOriginalJournal(
        rootDescriptor: Int32,
        sourceLeaf: String,
        originalHash: String
    ) throws {
        guard rootDescriptorMatchesCanonicalPath(
                rootDescriptor
              ),
              try hashRegularFile(
                directoryDescriptor: rootDescriptor,
                leaf: sourceLeaf,
                requiredPermissions: 0o600
              ) == originalHash,
              directorySynchronizer(rootDescriptor) == 0,
              rootDescriptorMatchesCanonicalPath(
                rootDescriptor
              ),
              try hashRegularFile(
                directoryDescriptor: rootDescriptor,
                leaf: sourceLeaf,
                requiredPermissions: 0o600
              ) == originalHash else {
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "旧恢复事务原记录补偿未通过持久化核对"
            )
        }
    }

    private func originalJournalAndAcceptedArchiveAbsent(
        rootDescriptor: Int32,
        journalID: String,
        expectedJournalHash: String
    ) throws -> Bool {
        guard rootDescriptorMatchesCanonicalPath(
                rootDescriptor
              ),
              try hashRegularFile(
                directoryDescriptor: rootDescriptor,
                leaf: "\(journalID).json",
                requiredPermissions: 0o600
              ) == expectedJournalHash else {
            return false
        }
        var archiveMetadata = stat()
        errno = 0
        let archiveResult = Darwin.fstatat(
            rootDescriptor,
            "Archive",
            &archiveMetadata,
            AT_SYMLINK_NOFOLLOW
        )
        if archiveResult != 0 {
            return errno == ENOENT
        }
        guard archiveMetadata.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        let archiveDescriptor = Darwin.openat(
            rootDescriptor,
            "Archive",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard archiveDescriptor >= 0 else { return false }
        defer { _ = Darwin.close(archiveDescriptor) }
        guard archiveDescriptorMatchesRootEntry(
            rootDescriptor: rootDescriptor,
            archiveDescriptor: archiveDescriptor
        ) else {
            return false
        }
        let acceptedMissing = try hashRegularFile(
            directoryDescriptor: archiveDescriptor,
            leaf: "\(journalID)-accepted.json",
            requiredPermissions: nil
        ) == nil
        return acceptedMissing
            && rootDescriptorMatchesCanonicalPath(
                rootDescriptor
            )
            && archiveDescriptorMatchesRootEntry(
                rootDescriptor: rootDescriptor,
                archiveDescriptor: archiveDescriptor
            )
    }

    func openRootDescriptor() throws -> Int32 {
        let descriptor = Darwin.open(
            rootURL.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0,
              rootDescriptorMatchesCanonicalPath(
                descriptor
              ) else {
            if descriptor >= 0 { _ = Darwin.close(descriptor) }
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "恢复事务根目录身份无法确认"
            )
        }
        return descriptor
    }

    private func openArchiveDescriptor(
        rootDescriptor: Int32
    ) throws -> Int32 {
        errno = 0
        if Darwin.mkdirat(
            rootDescriptor,
            "Archive",
            S_IRWXU
        ) != 0,
        errno != EEXIST {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let descriptor = Darwin.openat(
            rootDescriptor,
            "Archive",
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR,
              Darwin.fchmod(descriptor, S_IRWXU) == 0,
              archiveDescriptorMatchesRootEntry(
                rootDescriptor: rootDescriptor,
                archiveDescriptor: descriptor
              ) else {
            _ = Darwin.close(descriptor)
            throw V011SwitchError.invalidRecoveryJournal
        }
        return descriptor
    }

    private func archiveDescriptorMatchesRootEntry(
        rootDescriptor: Int32,
        archiveDescriptor: Int32
    ) -> Bool {
        var descriptorMetadata = stat()
        var entryMetadata = stat()
        return Darwin.fstat(
            archiveDescriptor,
            &descriptorMetadata
        ) == 0
            && descriptorMetadata.st_mode & S_IFMT == S_IFDIR
            && Darwin.fstatat(
                rootDescriptor,
                "Archive",
                &entryMetadata,
                AT_SYMLINK_NOFOLLOW
            ) == 0
            && entryMetadata.st_mode & S_IFMT == S_IFDIR
            && descriptorMetadata.st_dev == entryMetadata.st_dev
            && descriptorMetadata.st_ino == entryMetadata.st_ino
    }

    func rootDescriptorMatchesCanonicalPath(
        _ descriptor: Int32
    ) -> Bool {
        var descriptorMetadata = stat()
        var pathMetadata = stat()
        return Darwin.fstat(
            descriptor,
            &descriptorMetadata
        ) == 0
            && descriptorMetadata.st_mode & S_IFMT == S_IFDIR
            && lstat(rootURL.path, &pathMetadata) == 0
            && pathMetadata.st_mode & S_IFMT == S_IFDIR
            && descriptorMetadata.st_dev == pathMetadata.st_dev
            && descriptorMetadata.st_ino == pathMetadata.st_ino
    }

    private func hashRegularFile(
        directoryDescriptor: Int32,
        leaf: String,
        requiredPermissions: mode_t?
    ) throws -> String? {
        guard let data = try regularFileData(
            directoryDescriptor: directoryDescriptor,
            leaf: leaf,
            requiredPermissions: requiredPermissions
        ) else {
            return nil
        }
        return TOMLSemanticEngine.sha256(data)
    }

    private func regularFileData(
        directoryDescriptor: Int32,
        leaf: String,
        requiredPermissions: mode_t?
    ) throws -> Data? {
        errno = 0
        let descriptor = Darwin.openat(
            directoryDescriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "恢复事务记录无法通过锁定目录读取"
            )
        }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0 else {
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "恢复事务记录类型或权限不安全"
            )
        }
        let permissionsMatch = requiredPermissions.map {
            metadata.st_mode & 0o777 == $0
        } ?? true
        guard metadata.st_mode & S_IFMT == S_IFREG,
              permissionsMatch else {
            throw V011AcceptedJournalCommitIndeterminate(
                detail: "恢复事务记录类型或权限不安全"
            )
        }
        let handle = FileHandle(
            fileDescriptor: descriptor,
            closeOnDealloc: false
        )
        return try handle.readToEnd() ?? Data()
    }
}
