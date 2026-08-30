// SPDX-License-Identifier: AGPL-3.0-only

import Darwin
import Foundation

enum SessionWriterActivity: Equatable {
    case active
    case inactive
    case unknown
}

struct SessionWriterActivityProbe {
    func requireInactive(
        codexHome: URL,
        threadID: String
    ) throws {
        switch activity(
            codexHome: codexHome,
            threadID: threadID
        ) {
        case .inactive:
            return
        case .active:
            throw SessionCenterError.activeWriter
        case .unknown:
            throw SessionCenterError.writerActivityUnavailable
        }
    }

    func activity(
        codexHome: URL,
        threadID: String
    ) -> SessionWriterActivity {
        guard let parsedID = UUID(uuidString: threadID) else {
            return .unknown
        }
        let lockURL = codexHome
            .appendingPathComponent(
                "thread-writer-locks",
                isDirectory: true
            )
            .appendingPathComponent(
                parsedID.uuidString.lowercased() + ".lock",
                isDirectory: false
            )
        let descriptor = Darwin.open(
            lockURL.path,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            return errno == ENOENT ? .inactive : .unknown
        }
        defer { _ = Darwin.close(descriptor) }

        var metadata = stat()
        guard Darwin.fstat(descriptor, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return .unknown
        }
        guard flock(
            descriptor,
            LOCK_SH | LOCK_NB
        ) != 0 else {
            _ = flock(descriptor, LOCK_UN)
            return .inactive
        }
        return errno == EWOULDBLOCK || errno == EAGAIN
            ? .active : .unknown
    }
}

struct SessionRolloutSnapshot: Equatable, Hashable, Sendable {
    let device: dev_t
    let inode: ino_t
    let size: off_t
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int

    static func capture(at url: URL) -> Self? {
        var metadata = stat()
        guard Darwin.lstat(url.path, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG else {
            return nil
        }
        return Self(
            device: metadata.st_dev,
            inode: metadata.st_ino,
            size: metadata.st_size,
            modifiedSeconds: metadata.st_mtimespec.tv_sec,
            modifiedNanoseconds: metadata.st_mtimespec.tv_nsec
        )
    }
}

enum SessionRolloutStabilityGuard {
    static func requireUnchanged(
        initial: SessionRolloutSnapshot,
        final: SessionRolloutSnapshot?
    ) throws {
        guard let final, final == initial else {
            throw SessionCenterError.changedDuringRead
        }
    }
}

struct GuardedContinuationPacketExtractor {
    func packet(
        at url: URL,
        threadID: String,
        codexHome: URL
    ) async throws -> SessionContinuationPacket {
        let writerProbe = SessionWriterActivityProbe()
        try writerProbe.requireInactive(
            codexHome: codexHome,
            threadID: threadID
        )
        guard let initialSnapshot = SessionRolloutSnapshot.capture(
            at: url
        ) else {
            throw SessionCenterError.unsafePath
        }
        let worker = Task.detached(
            priority: .userInitiated
        ) {
            try RolloutContinuationPacketExtractor()
                .packet(
                    at: url,
                    threadID: threadID,
                    authorization: SessionReadAuthorization(
                        metadataAllowed: true,
                        visibleBodyAllowed: true
                    )
                )
        }
        let packet = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try writerProbe.requireInactive(
            codexHome: codexHome,
            threadID: threadID
        )
        try SessionRolloutStabilityGuard.requireUnchanged(
            initial: initialSnapshot,
            final: SessionRolloutSnapshot.capture(at: url)
        )
        return packet
    }
}

enum SessionContinuationFailure: String, Equatable {
    case encryptedToolOutputDecodeFailure =
        "encrypted_tool_output_decode_failure"
    case gitMetadataPermissionDenied =
        "git_metadata_permission_denied"
    case interruptedExternalToolMayHaveCommitted =
        "interrupted_external_tool_may_have_committed"
    case interruptedTurn = "interrupted_turn"

    var notice: String {
        switch self {
        case .encryptedToolOutputDecodeFailure:
            return "旧任务记录中的加密工具结果无法解码，继续原任务可能重复失败。"
        case .gitMetadataPermissionDenied:
            return "工作树改动通常仍在，失败是当前 Git 元数据写权限边界。"
        case .interruptedExternalToolMayHaveCommitted:
            return "旧任务中断前，一个没有只读保证的外部工具已返回完成；外部状态可能已经改变。"
        case .interruptedTurn:
            return "旧任务最近一次明确记录的运行已中断，最后工作可能未完成。"
        }
    }

    var recoveryInstruction: String {
        switch self {
        case .encryptedToolOutputDecodeFailure:
            return "不要反复续接或手工改写历史；请新建Codex任务，粘贴本包，并保留旧任务作只读记录。"
        case .gitMetadataPermissionDenied:
            return "先现场核对工作树并保留改动，只为明确的 git add/commit 申请一次权限；不要删除 lock、开放全盘权限、重试等价命令或推送。"
        case .interruptedExternalToolMayHaveCommitted:
            return "不要直接重试；先在对应外部系统读回权威结果，确认未完成后再执行。"
        case .interruptedTurn:
            return "粘贴本包后，先核对旧任务最后可见进度和当前工作区，只继续尚未完成的步骤。"
        }
    }

    var excludedCategory: String {
        switch self {
        case .encryptedToolOutputDecodeFailure:
            return "无法解码的加密工具结果"
        case .gitMetadataPermissionDenied:
            return "Git元数据写权限被拒"
        case .interruptedExternalToolMayHaveCommitted:
            return "非只读外部工具状态元数据"
        case .interruptedTurn:
            return "任务中断状态元数据"
        }
    }

    var impliesExcludedEncryptedState: Bool {
        switch self {
        case .encryptedToolOutputDecodeFailure:
            return true
        case .gitMetadataPermissionDenied:
            return false
        case .interruptedExternalToolMayHaveCommitted:
            return false
        case .interruptedTurn:
            return false
        }
    }
}

struct SessionTurnOutcomeTracker {
    private enum Outcome: Equatable {
        case started
        case completed
        case interrupted
    }

    private var latestOutcome: Outcome?
    private var completedPotentialExternalWrite = false

    mutating func observe(_ object: [String: Any]) {
        guard object["type"] as? String == "event_msg",
              let payload = object["payload"] as? [String: Any],
              let type = payload["type"] as? String else {
            return
        }
        switch type {
        case "task_started":
            latestOutcome = .started
            completedPotentialExternalWrite = false
        case "task_complete":
            latestOutcome = .completed
        case "mcp_tool_call_end"
            where latestOutcome == .started:
            guard let result = payload["result"] as? [String: Any],
                  result["Ok"] != nil,
                  payload["read_only_hint"] as? Bool != true else {
                return
            }
            completedPotentialExternalWrite = true
        case "turn_aborted"
            where payload["reason"] as? String == "interrupted":
            latestOutcome = .interrupted
        default:
            break
        }
    }

    var continuationFailure: SessionContinuationFailure? {
        guard latestOutcome == .interrupted else { return nil }
        return completedPotentialExternalWrite
            ? .interruptedExternalToolMayHaveCommitted
            : .interruptedTurn
    }
}
