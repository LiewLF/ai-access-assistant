// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import CryptoKit
import Foundation

struct V011AnchoredDirectory {
    let descriptor: Int32
    let canonicalURL: URL?
    let parentDescriptor: Int32?
    let parentLeaf: String?

    static func withCanonicalRoot<T>(
        _ rootURL: URL,
        create: Bool,
        _ body: (V011AnchoredDirectory) throws -> T
    ) throws -> T {
        let canonical = rootURL.standardizedFileURL
        if create && !FileManager.default.fileExists(atPath: canonical.path) {
            try FileManager.default.createDirectory(
                at: canonical,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let descriptor = Darwin.open(
            canonical.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.close(descriptor) }
        let root = V011AnchoredDirectory(
            descriptor: descriptor,
            canonicalURL: canonical,
            parentDescriptor: nil,
            parentLeaf: nil
        )
        guard root.verifyIdentity(),
              Darwin.fchmod(descriptor, S_IRWXU) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let result = try body(root)
        guard root.verifyIdentity() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return result
    }

    func withSubdirectory<T>(
        _ leaf: String,
        create: Bool,
        _ body: (V011AnchoredDirectory) throws -> T
    ) throws -> T {
        try Self.requireBasename(leaf)
        if create {
            errno = 0
            if Darwin.mkdirat(descriptor, leaf, S_IRWXU) != 0,
               errno != EEXIST {
                throw V011SwitchError.invalidRecoveryJournal
            }
        }
        let childDescriptor = Darwin.openat(
            descriptor,
            leaf,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard childDescriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.close(childDescriptor) }
        let child = V011AnchoredDirectory(
            descriptor: childDescriptor,
            canonicalURL: nil,
            parentDescriptor: descriptor,
            parentLeaf: leaf
        )
        guard child.verifyIdentity(),
              Darwin.fchmod(childDescriptor, S_IRWXU) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let result = try body(child)
        guard Darwin.fsync(childDescriptor) == 0,
              child.verifyIdentity(),
              verifyIdentity() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return result
    }

    func data(
        _ leaf: String,
        maximumBytes: Int,
        requiredPermissions: mode_t? = nil
    ) throws -> Data? {
        try Self.requireBasename(leaf)
        errno = 0
        let fileDescriptor = Darwin.openat(
            descriptor,
            leaf,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        if fileDescriptor < 0 {
            if errno == ENOENT { return nil }
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.close(fileDescriptor) }
        var metadata = stat()
        guard Darwin.fstat(fileDescriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_size >= 0,
              UInt64(metadata.st_size) <= UInt64(maximumBytes),
              requiredPermissions.map({
                  metadata.st_mode & 0o777 == $0
              }) ?? true else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        let handle = FileHandle(
            fileDescriptor: fileDescriptor,
            closeOnDealloc: false
        )
        let result = try handle.readToEnd() ?? Data()
        guard result.count <= maximumBytes,
              verifyIdentity() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return result
    }

    func hash(
        _ leaf: String,
        maximumBytes: Int,
        requiredPermissions: mode_t? = nil
    ) throws -> String? {
        try data(
            leaf,
            maximumBytes: maximumBytes,
            requiredPermissions: requiredPermissions
        ).map(TOMLSemanticEngine.sha256)
    }

    func writeAtomic(
        _ data: Data,
        leaf: String,
        expectedHash: String?,
        permissions: mode_t
    ) throws {
        try Self.requireBasename(leaf)
        let existing = try self.data(
            leaf,
            maximumBytes: max(data.count, 1) +
                SessionCoreClient.maximumRecoveryJournalBytes,
            requiredPermissions: nil
        )
        guard existing.map(TOMLSemanticEngine.sha256) == expectedHash else {
            throw V011SwitchError.concurrentConfigurationChange
        }
        let temporaryLeaf = ".\(leaf).\(UUID().uuidString).tmp"
        try Self.requireBasename(temporaryLeaf)
        let fileDescriptor = Darwin.openat(
            descriptor,
            temporaryLeaf,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            permissions
        )
        guard fileDescriptor >= 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        var renamed = false
        defer {
            _ = Darwin.close(fileDescriptor)
            if !renamed {
                _ = Darwin.unlinkat(descriptor, temporaryLeaf, 0)
            }
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < rawBuffer.count {
                let written = Darwin.write(
                    fileDescriptor,
                    base.advanced(by: offset),
                    rawBuffer.count - offset
                )
                guard written > 0 else {
                    throw V011SwitchError.invalidRecoveryJournal
                }
                offset += written
            }
        }
        guard Darwin.fchmod(fileDescriptor, permissions) == 0,
              Darwin.fsync(fileDescriptor) == 0,
              verifyIdentity(),
              Darwin.renameat(
                  descriptor,
                  temporaryLeaf,
                  descriptor,
                  leaf
              ) == 0 else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        renamed = true
        guard Darwin.fsync(descriptor) == 0,
              try self.data(
                  leaf,
                  maximumBytes: max(data.count, 1),
                  requiredPermissions: permissions
              ) == data,
              verifyIdentity() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
    }

    func removeRegularFile(
        _ leaf: String,
        expectedHash: String,
        maximumBytes: Int
    ) throws {
        guard try hash(
            leaf,
            maximumBytes: maximumBytes,
            requiredPermissions: 0o600
        ) == expectedHash,
        Darwin.unlinkat(descriptor, leaf, 0) == 0,
        Darwin.fsync(descriptor) == 0,
        try hash(
            leaf,
            maximumBytes: maximumBytes,
            requiredPermissions: nil
        ) == nil,
        verifyIdentity() else {
            throw V011SwitchError.concurrentConfigurationChange
        }
    }

    func entries() throws -> [String] {
        let duplicate = Darwin.dup(descriptor)
        guard duplicate >= 0,
              let stream = Darwin.fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw V011SwitchError.invalidRecoveryJournal
        }
        defer { _ = Darwin.closedir(stream) }
        var names: [String] = []
        while let entry = Darwin.readdir(stream) {
            let name = withUnsafePointer(to: entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1_024) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        guard verifyIdentity() else {
            throw V011SwitchError.invalidRecoveryJournal
        }
        return names
    }

    func verifyIdentity() -> Bool {
        var descriptorMetadata = stat()
        guard Darwin.fstat(descriptor, &descriptorMetadata) == 0,
              descriptorMetadata.st_mode & S_IFMT == S_IFDIR else {
            return false
        }
        if let canonicalURL {
            var pathMetadata = stat()
            return lstat(canonicalURL.path, &pathMetadata) == 0
                && pathMetadata.st_mode & S_IFMT == S_IFDIR
                && descriptorMetadata.st_dev == pathMetadata.st_dev
                && descriptorMetadata.st_ino == pathMetadata.st_ino
        }
        guard let parentDescriptor, let parentLeaf else { return false }
        var entryMetadata = stat()
        return Darwin.fstatat(
            parentDescriptor,
            parentLeaf,
            &entryMetadata,
            AT_SYMLINK_NOFOLLOW
        ) == 0
            && entryMetadata.st_mode & S_IFMT == S_IFDIR
            && descriptorMetadata.st_dev == entryMetadata.st_dev
            && descriptorMetadata.st_ino == entryMetadata.st_ino
    }

    private static func requireBasename(_ leaf: String) throws {
        guard !leaf.isEmpty,
              leaf != ".",
              leaf != "..",
              !leaf.contains("/"),
              !leaf.contains("\u{0}") else {
            throw V011SwitchError.invalidRecoveryJournal
        }
    }
}

func preserveRawRecordPreimage(
    _ data: Data,
    for targetURL: URL
) throws {
    try V011AnchoredDirectory.withCanonicalRoot(
        targetURL.deletingLastPathComponent(),
        create: false
    ) { root in
        try preserveRawRecordPreimage(
            data,
            targetLeaf: targetURL.lastPathComponent,
            root: root
        )
    }
}

func preserveRawRecordPreimage(
    _ data: Data,
    targetLeaf: String,
    root: V011AnchoredDirectory
) throws {
    let hash = TOMLSemanticEngine.sha256(data)
    try root.withSubdirectory(".RawPreimages", create: true) { rawRoot in
        try rawRoot.withSubdirectory(targetLeaf, create: true) { recordRoot in
            let leaf = "\(hash).raw"
            if let existing = try recordRoot.data(
                leaf,
                maximumBytes: SessionCoreClient.maximumRecoveryJournalBytes,
                requiredPermissions: 0o600
            ) {
                guard existing == data,
                      TOMLSemanticEngine.sha256(existing) == hash else {
                    throw V011SwitchError.concurrentConfigurationChange
                }
                return
            }
            try recordRoot.writeAtomic(
                data,
                leaf: leaf,
                expectedHash: nil,
                permissions: 0o600
            )
        }
    }
}

func rawRecordPreimage(
    for targetURL: URL,
    hash: String
) throws -> Data {
    try V011AnchoredDirectory.withCanonicalRoot(
        targetURL.deletingLastPathComponent(),
        create: false
    ) { root in
        try rawRecordPreimage(
            targetLeaf: targetURL.lastPathComponent,
            hash: hash,
            root: root
        )
    }
}

func rawRecordPreimage(
    targetLeaf: String,
    hash: String,
    root: V011AnchoredDirectory
) throws -> Data {
    try root.withSubdirectory(".RawPreimages", create: false) { rawRoot in
        try rawRoot.withSubdirectory(targetLeaf, create: false) { recordRoot in
            guard let data = try recordRoot.data(
                "\(hash).raw",
                maximumBytes: SessionCoreClient.maximumRecoveryJournalBytes,
                requiredPermissions: 0o600
            ), TOMLSemanticEngine.sha256(data) == hash else {
                throw V011SwitchError.invalidRecoveryJournal
            }
            return data
        }
    }
}

func mergeKnownJSONValue(
    _ encoded: Any,
    preserving original: Any
) -> Any {
    if let encodedObject = encoded as? [String: Any],
       let originalObject = original as? [String: Any] {
        var merged = originalObject
        for (key, value) in encodedObject {
            if let previous = originalObject[key] {
                merged[key] = mergeKnownJSONValue(
                    value,
                    preserving: previous
                )
            } else {
                merged[key] = value
            }
        }
        return merged
    }
    if let encodedArray = encoded as? [Any],
       let originalArray = original as? [Any] {
        var originalByID: [String: Any] = [:]
        for item in originalArray {
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String,
                  originalByID[id] == nil else {
                continue
            }
            originalByID[id] = item
        }
        return encodedArray.map { item in
            guard let object = item as? [String: Any],
                  let id = object["id"] as? String,
                  let previous = originalByID[id] else {
                return item
            }
            return mergeKnownJSONValue(
                item,
                preserving: previous
            )
        }
    }
    return encoded
}

enum V011AtomicWriteClassification {
    case original
    case intended
    case foreign
}

func classifyAtomicWrite(
    at url: URL,
    originalHash: String?,
    intendedHash: String
) -> V011AtomicWriteClassification {
    classifyAtomicWrite(
        currentHash: SessionSyncFileSafety.hashIfPresent(url),
        originalHash: originalHash,
        intendedHash: intendedHash
    )
}

func classifyAtomicWrite(
    currentHash: String?,
    originalHash: String?,
    intendedHash: String
) -> V011AtomicWriteClassification {
    if currentHash == originalHash {
        return .original
    }
    if currentHash == intendedHash {
        return .intended
    }
    return .foreign
}
