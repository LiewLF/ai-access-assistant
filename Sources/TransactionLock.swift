import Darwin
import Foundation

enum TransactionLockError: LocalizedError, Equatable {
    case alreadyLocked(ownerPID: Int32?)
    case unsafeLockFile
    case createFailed(Int32)
    case writeFailed

    var errorDescription: String? {
        switch self {
        case let .alreadyLocked(ownerPID):
            return ownerPID.map { "另一个切换事务正在运行，PID \($0)" } ?? "另一个切换事务正在运行"
        case .unsafeLockFile:
            return "事务锁不是普通文件或路径不安全"
        case let .createFailed(code):
            return "无法创建事务锁：errno \(code)"
        case .writeFailed:
            return "事务锁写入失败"
        }
    }
}

struct TransactionLockRecord: Codable, Equatable {
    let processIdentifier: Int32
    let transactionID: String
    let startedAt: Date
    let expectedConfigHash: String?
}

final class ProviderTransactionLock {
    let fileURL: URL
    private(set) var record: TransactionLockRecord?
    private var descriptor: Int32 = -1

    init(fileURL: URL) {
        self.fileURL = fileURL.standardizedFileURL
    }

    deinit {
        release()
    }

    func acquire(transactionID: String, expectedConfigHash: String?) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try reclaimStaleLockIfSafe()
        let flags = O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW
        let fd = Darwin.open(fileURL.path, flags, S_IRUSR | S_IWUSR)
        if fd < 0 {
            if errno == EEXIST {
                throw TransactionLockError.alreadyLocked(ownerPID: try? existingRecord()?.processIdentifier)
            }
            throw TransactionLockError.createFailed(errno)
        }
        descriptor = fd
        let newRecord = TransactionLockRecord(
            processIdentifier: getpid(),
            transactionID: transactionID,
            startedAt: Date(),
            expectedConfigHash: expectedConfigHash
        )
        let data = try JSONEncoder.lockEncoder.encode(newRecord)
        let written = data.withUnsafeBytes { bytes in
            Darwin.write(fd, bytes.baseAddress, bytes.count)
        }
        guard written == data.count, fsync(fd) == 0 else {
            release()
            throw TransactionLockError.writeFailed
        }
        record = newRecord
    }

    func release() {
        if descriptor >= 0 {
            Darwin.close(descriptor)
            descriptor = -1
        }
        guard let record else { return }
        if let current = try? existingRecord(), current.transactionID == record.transactionID {
            try? FileManager.default.removeItem(at: fileURL)
        }
        self.record = nil
    }

    func existingRecord() throws -> TransactionLockRecord? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TransactionLockError.unsafeLockFile
        }
        return try JSONDecoder.lockDecoder.decode(TransactionLockRecord.self, from: Data(contentsOf: fileURL))
    }

    func reclaimStaleLockIfSafe() throws {
        guard let current = try existingRecord() else { return }
        if current.processIdentifier > 0,
           kill(current.processIdentifier, 0) == 0 || errno == EPERM {
            throw TransactionLockError.alreadyLocked(ownerPID: current.processIdentifier)
        }
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw TransactionLockError.unsafeLockFile
        }
        try FileManager.default.removeItem(at: fileURL)
    }
}

private extension JSONEncoder {
    static var lockEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var lockDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
