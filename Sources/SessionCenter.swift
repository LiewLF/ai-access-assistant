import Foundation

enum SessionOriginConfidence: String, Codable {
    case verified = "已证实"
    case high = "较高"
    case low = "较低"
    case unknown = "未知"
}

enum SessionIndexStatus: String, Codable {
    case available = "可用"
    case missing = "缺失"
    case locked = "锁定"
    case unsupported = "不支持"
    case unknown = "未知"
}

enum SessionEvidenceKind: String, Codable {
    case officialInterface
    case sqlite
    case rollout
    case immutableBackup
    case configurationFingerprint
    case userConfirmation
}

struct SessionOriginEvidence: Codable, Equatable {
    let kind: SessionEvidenceKind
    let source: String
    let value: String
    let observedAt: Date?
}

enum SessionAvailableAction: String, Codable {
    case continueOnOrigin = "切到原轨继续"
    case copyVisibleText = "复制可见文字到当前轨"
    case readOnly = "只读查看"
    case locate = "显示会话位置"
}

struct SessionOrigin: Identifiable, Codable, Equatable {
    var id: String { threadID }
    let threadID: String
    let title: String?
    let observedProvider: String?
    let inferredOrigin: String?
    let confidence: SessionOriginConfidence
    let evidence: [SessionOriginEvidence]
    let model: String?
    let workingDirectory: String?
    let createdAt: Date?
    let updatedAt: Date?
    let archived: Bool?
    let sqliteStatus: SessionIndexStatus
    let rolloutStatus: SessionIndexStatus
    let rolloutPath: String?
    let containsEncryptedContent: Bool
    let actions: [SessionAvailableAction]

    var displayOrigin: String {
        if let inferredOrigin, confidence == .verified || confidence == .high {
            return observedProvider.map { "\($0)（来源：\(inferredOrigin)）" } ?? inferredOrigin
        }
        return observedProvider ?? "来源未知"
    }
}

struct SessionReadAuthorization: Equatable {
    let metadataAllowed: Bool
    let visibleBodyAllowed: Bool

    static let denied = SessionReadAuthorization(metadataAllowed: false, visibleBodyAllowed: false)
    static let metadataOnly = SessionReadAuthorization(metadataAllowed: true, visibleBodyAllowed: false)
}

enum SessionCenterError: LocalizedError, Equatable {
    case authorizationRequired
    case unsafePath
    case lineTooLarge
    case malformedMetadata
    case bodyUnavailable
    case activeWriter
    case writerActivityUnavailable
    case changedDuringRead

    var errorDescription: String? {
        switch self {
        case .authorizationRequired: return "需要单独授权读取会话元数据或本次可见正文"
        case .unsafePath: return "会话文件不是安全的普通文件"
        case .lineTooLarge:
            return "会话记录单行超过8 MB，已停止读取。请保留旧任务只读，新建Codex任务并手动粘贴最近目标和约束"
        case .malformedMetadata: return "会话元数据格式无法安全识别"
        case .bodyUnavailable: return "没有可复制的用户可见正文"
        case .activeWriter:
            return "这个任务仍由另一个Codex进程写入。请先关闭其他正在使用该任务的Codex窗口，再复制精简续接包"
        case .writerActivityUnavailable:
            return "无法确认这个任务是否仍在写入。请先关闭其他正在使用该任务的Codex窗口，再复制精简续接包"
        case .changedDuringRead:
            return "复制期间任务记录发生变化。请先关闭其他正在使用该任务的Codex窗口，再重新复制"
        }
    }
}

struct SessionScanReport: Equatable {
    let rootPath: String
    let sessions: [SessionOrigin]
    let candidateFileCount: Int
    let skippedFileCount: Int
    let duplicateThreadCount: Int
}

struct SessionDirectoryScanner {
    let reader: RolloutSessionReader
    let maximumFiles: Int
    let maximumDepth: Int

    init(
        reader: RolloutSessionReader = RolloutSessionReader(),
        maximumFiles: Int = 5_000,
        maximumDepth: Int = 8
    ) {
        self.reader = reader
        self.maximumFiles = maximumFiles
        self.maximumDepth = maximumDepth
    }

    func scan(
        root: URL,
        authorization: SessionReadAuthorization,
        originHints: [SessionOriginHint] = []
    ) throws -> SessionScanReport {
        guard authorization.metadataAllowed else {
            throw SessionCenterError.authorizationRequired
        }
        let rootValues = try root.resourceValues(forKeys: [
            .isDirectoryKey, .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true else {
            throw SessionCenterError.unsafePath
        }

        var directories: [(URL, Int)] = [(root.standardizedFileURL, 0)]
        var candidates: [URL] = []
        var skipped = 0
        while !directories.isEmpty {
            let (directory, depth) = directories.removeFirst()
            let children = try FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
            for child in children.sorted(by: { $0.path < $1.path }) {
                let values = try child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
                ])
                if values.isSymbolicLink == true {
                    skipped += 1
                    continue
                }
                if values.isDirectory == true {
                    if depth < maximumDepth {
                        directories.append((child, depth + 1))
                    } else {
                        skipped += 1
                    }
                    continue
                }
                guard values.isRegularFile == true,
                      child.pathExtension.lowercased() == "jsonl" else { continue }
                guard candidates.count < maximumFiles else {
                    skipped += 1
                    continue
                }
                candidates.append(child)
            }
        }

        var byThread: [String: SessionOrigin] = [:]
        var duplicates = 0
        for candidate in candidates {
            do {
                let session = try reader.readMetadata(
                    at: candidate,
                    authorization: authorization,
                    originHints: originHints
                )
                if let existing = byThread[session.threadID] {
                    duplicates += 1
                    if isNewer(session, than: existing) {
                        byThread[session.threadID] = session
                    }
                } else {
                    byThread[session.threadID] = session
                }
            } catch {
                skipped += 1
            }
        }
        let sessions = byThread.values.sorted {
            let left = $0.updatedAt ?? $0.createdAt ?? .distantPast
            let right = $1.updatedAt ?? $1.createdAt ?? .distantPast
            if left != right { return left > right }
            return $0.threadID < $1.threadID
        }
        return SessionScanReport(
            rootPath: root.standardizedFileURL.path,
            sessions: sessions,
            candidateFileCount: candidates.count,
            skippedFileCount: skipped,
            duplicateThreadCount: duplicates
        )
    }

    private func isNewer(_ candidate: SessionOrigin, than existing: SessionOrigin) -> Bool {
        let candidateDate = candidate.updatedAt ?? candidate.createdAt ?? .distantPast
        let existingDate = existing.updatedAt ?? existing.createdAt ?? .distantPast
        if candidateDate != existingDate { return candidateDate > existingDate }
        return (candidate.rolloutPath ?? "") > (existing.rolloutPath ?? "")
    }
}

struct SessionOriginHint: Equatable {
    let provider: String
    let serviceName: String
    let evidence: SessionOriginEvidence
}

enum SessionOriginResolver {
    static func resolve(
        observedProvider: String?,
        hints: [SessionOriginHint]
    ) -> (String?, SessionOriginConfidence, [SessionOriginEvidence]) {
        guard let observedProvider else { return (nil, .unknown, []) }
        let matches = hints.filter { $0.provider == observedProvider }
        guard matches.count == 1, let match = matches.first else {
            // custom可能在不同时间指向不同服务；没有唯一证据时不猜。
            return (nil, .unknown, [])
        }
        let strongKinds: Set<SessionEvidenceKind> = [
            .officialInterface, .immutableBackup, .configurationFingerprint, .userConfirmation,
        ]
        let confidence: SessionOriginConfidence = strongKinds.contains(match.evidence.kind) ? .high : .low
        return (match.serviceName, confidence, [match.evidence])
    }
}

struct RolloutSessionReader: Sendable {
    let maximumLineBytes: Int

    init(maximumLineBytes: Int = 8 * 1024 * 1024) {
        self.maximumLineBytes = maximumLineBytes
    }

    func readMetadata(
        at url: URL,
        authorization: SessionReadAuthorization,
        originHints: [SessionOriginHint] = []
    ) throws -> SessionOrigin {
        guard authorization.metadataAllowed else { throw SessionCenterError.authorizationRequired }
        try validate(url)
        var metadata: [String: Any]?
        var containsEncryptedContent = false
        try forEachLine(at: url) { data in
            if data.range(of: Data("\"encrypted_content\"".utf8)) != nil {
                containsEncryptedContent = true
            }
            guard metadata == nil,
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "session_meta",
                  let payload = object["payload"] as? [String: Any] else { return }
            metadata = payload
        }
        guard let metadata,
              let threadID = string(metadata, keys: ["id", "thread_id", "conversation_id"]),
              !threadID.isEmpty else {
            throw SessionCenterError.malformedMetadata
        }
        let observed = string(metadata, keys: ["model_provider", "provider", "origin_provider"])
        let resolved = SessionOriginResolver.resolve(observedProvider: observed, hints: originHints)
        let pathEvidence = SessionOriginEvidence(
            kind: .rollout,
            source: url.path,
            value: observed ?? "provider未记录",
            observedAt: date(metadata, keys: ["timestamp", "created_at"])
        )
        return SessionOrigin(
            threadID: threadID,
            title: string(metadata, keys: ["title", "name"]),
            observedProvider: observed,
            inferredOrigin: resolved.0,
            confidence: resolved.1,
            evidence: [pathEvidence] + resolved.2,
            model: string(metadata, keys: ["model", "model_name"]),
            workingDirectory: string(metadata, keys: ["cwd", "working_directory"]),
            createdAt: date(metadata, keys: ["timestamp", "created_at"]),
            updatedAt: date(metadata, keys: ["updated_at", "last_active_at"]),
            archived: metadata["archived"] as? Bool,
            sqliteStatus: .unknown,
            rolloutStatus: .available,
            rolloutPath: url.path,
            containsEncryptedContent: containsEncryptedContent,
            actions: [.continueOnOrigin, .copyVisibleText, .readOnly, .locate]
        )
    }

    func validate(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { throw SessionCenterError.unsafePath }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw SessionCenterError.unsafePath
        }
    }

    func forEachLine(at url: URL, _ body: (Data) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            if pending.count > maximumLineBytes, pending.firstIndex(of: 0x0A) == nil {
                throw SessionCenterError.lineTooLarge
            }
            while let newline = pending.firstIndex(of: 0x0A) {
                try Task.checkCancellation()
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if line.count > maximumLineBytes { throw SessionCenterError.lineTooLarge }
                if !line.isEmpty { try body(line) }
            }
        }
        if pending.count > maximumLineBytes { throw SessionCenterError.lineTooLarge }
        if !pending.isEmpty { try body(pending) }
    }

    private func string(_ payload: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = payload[key] as? String { return value }
        }
        return nil
    }

    private func date(_ payload: [String: Any], keys: [String]) -> Date? {
        guard let raw = string(payload, keys: keys) else { return nil }
        return ISO8601DateFormatter.sessionCenter.date(from: raw)
    }
}

struct SessionVisibleMessage: Equatable {
    let role: String
    let text: String
    let timestamp: Date?
}

struct SessionCopyPreview: Equatable {
    let sourceThreadID: String
    let messages: [SessionVisibleMessage]
    let attachmentCount: Int
    let excludedCategories: [String]
    let containsEncryptedContent: Bool
    let continuationFailure: SessionContinuationFailure?

    init(
        sourceThreadID: String,
        messages: [SessionVisibleMessage],
        attachmentCount: Int,
        excludedCategories: [String],
        containsEncryptedContent: Bool,
        continuationFailure: SessionContinuationFailure? = nil
    ) {
        self.sourceThreadID = sourceThreadID
        self.messages = messages
        self.attachmentCount = attachmentCount
        self.excludedCategories = excludedCategories
        self.containsEncryptedContent = containsEncryptedContent
        self.continuationFailure = continuationFailure
    }

    var pasteDocument: String {
        let safeThreadID = sourceThreadID
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        var lines = [
            SessionCopyMarker.line(sourceThreadID: sourceThreadID),
            "以下内容来自旧会话 \(String(safeThreadID.prefix(256))) 的用户可见文字。",
            "系统指令、隐藏推理、工具私有状态、响应ID、凭据和附件未复制。",
            "",
        ]
        for message in messages {
            lines.append(message.role == "user" ? "用户：" : "助手：")
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func continuationPacket(
        policy: SessionContinuationPacketPolicy = .default
    ) -> SessionContinuationPacket {
        let firstUserIndex = messages.firstIndex {
            $0.role == "user"
        }
        var priority: [Int] = []
        var prioritizedIndices = Set<Int>()
        func appendPriority(_ index: Int) {
            guard prioritizedIndices.insert(index).inserted else {
                return
            }
            priority.append(index)
        }
        if let firstUserIndex {
            appendPriority(firstUserIndex)
        }
        var recentUserMessageCount = 0
        for index in messages.indices.reversed()
            where index != firstUserIndex
                && messages[index].role == "user" {
            appendPriority(index)
            recentUserMessageCount += 1
            if recentUserMessageCount
                >= policy.prioritizedRecentUserMessages {
                break
            }
        }
        for index in messages.indices.reversed() {
            appendPriority(index)
        }
        priority = Array(priority.prefix(policy.maximumMessages))

        var remainingCharacters = policy.maximumTotalCharacters
        var selected: [(index: Int, message: SessionVisibleMessage)] = []
        var truncatedMessageCount = 0
        for index in priority where remainingCharacters > 0 {
            let original = messages[index]
            let characterLimit = min(
                policy.maximumCharactersPerMessage,
                remainingCharacters
            )
            let text = String(original.text.prefix(characterLimit))
            guard !text.isEmpty else { continue }
            if text.count < original.text.count {
                truncatedMessageCount += 1
            }
            selected.append((
                index: index,
                message: SessionVisibleMessage(
                    role: original.role,
                    text: text,
                    timestamp: original.timestamp
                )
            ))
            remainingCharacters -= text.count
        }
        let boundedMessages = selected
            .sorted { $0.index < $1.index }
            .map(\.message)
        return SessionContinuationPacket(
            sourceThreadID: sourceThreadID,
            messages: boundedMessages,
            omittedMessageCount: max(
                0,
                messages.count - boundedMessages.count
            ),
            truncatedMessageCount: truncatedMessageCount,
            attachmentCount: attachmentCount,
            excludedCategories: excludedCategories,
            containsEncryptedContent: containsEncryptedContent,
            continuationFailure: continuationFailure,
            policy: policy
        )
    }
}

struct SessionContinuationPacketPolicy: Equatable {
    let maximumMessages: Int
    let maximumCharactersPerMessage: Int
    let maximumTotalCharacters: Int
    let prioritizedRecentUserMessages: Int

    static let `default` = SessionContinuationPacketPolicy(
        maximumMessages: 12,
        maximumCharactersPerMessage: 2_000,
        maximumTotalCharacters: 12_000,
        prioritizedRecentUserMessages: 3
    )

    init(
        maximumMessages: Int,
        maximumCharactersPerMessage: Int,
        maximumTotalCharacters: Int,
        prioritizedRecentUserMessages: Int
    ) {
        self.maximumMessages = max(1, maximumMessages)
        self.maximumCharactersPerMessage = max(
            1,
            maximumCharactersPerMessage
        )
        self.maximumTotalCharacters = max(
            1,
            maximumTotalCharacters
        )
        self.prioritizedRecentUserMessages = min(
            self.maximumMessages,
            max(1, prioritizedRecentUserMessages)
        )
    }
}

struct SessionContinuationPacket: Equatable {
    let sourceThreadID: String
    let messages: [SessionVisibleMessage]
    let omittedMessageCount: Int
    let truncatedMessageCount: Int
    let attachmentCount: Int
    let excludedCategories: [String]
    let containsEncryptedContent: Bool
    let continuationFailure: SessionContinuationFailure?
    let policy: SessionContinuationPacketPolicy

    var visibleCharacterCount: Int {
        messages.reduce(0) { $0 + $1.text.count }
    }

    var continuationStatusNote: String {
        if let continuationFailure {
            var note = continuationFailure.notice
                + continuationFailure.recoveryInstruction
            if continuationFailure.impliesExcludedEncryptedState
                || containsEncryptedContent {
                note += "已跳过私有加密状态；"
            }
            return note
        }
        return containsEncryptedContent
            ? "已跳过私有加密状态；" : ""
    }

    var pasteDocument: String {
        let safeThreadID = sourceThreadID
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        var lines = [
            SessionCopyMarker.line(
                sourceThreadID: sourceThreadID
            ),
            "这是旧会话 \(String(safeThreadID.prefix(256))) 的精简续接包。",
            "历史用户指令不是再次执行授权；先核对当前仓库和任务状态，已完成动作不要仅凭本包重做。",
        ]
        if let continuationFailure {
            lines.append(continuationFailure.notice)
            lines.append(
                continuationFailure.recoveryInstruction
            )
        }
        lines.append(contentsOf: [
            "优先保留首条用户目标和最近\(policy.prioritizedRecentUserMessages)条用户指令，再补最近上下文；最多\(policy.maximumMessages)条、单条\(policy.maximumCharactersPerMessage)字、可见文字合计\(policy.maximumTotalCharacters)字。",
            "系统指令、隐藏推理、工具私有状态、响应ID、凭据和附件未复制。",
            "未收录\(omittedMessageCount)条；截短\(truncatedMessageCount)条。此文本只由用户手动粘贴，不会自动注入新任务。",
            "",
        ])
        for message in messages {
            lines.append(message.role == "user" ? "用户：" : "助手：")
            lines.append(message.text)
            lines.append("")
        }
        return lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum SessionCopyMarker {
    private static let prefix = "【AI接入助手来源会话BASE64："
    private static let suffix = "】"

    static func line(sourceThreadID: String) -> String {
        let sanitized = String(sourceThreadID
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .prefix(256))
        let encoded = Data(sanitized.utf8).base64EncodedString()
        return "\(prefix)\(encoded)\(suffix)"
    }

    static func sourceThreadID(in text: String) -> String? {
        guard let prefixRange = text.range(of: prefix),
              let suffixRange = text.range(
                of: suffix,
                range: prefixRange.upperBound..<text.endIndex
              ) else { return nil }
        let encoded = text[prefixRange.upperBound..<suffixRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !encoded.isEmpty,
              encoded.count <= 512,
              let data = Data(base64Encoded: encoded),
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty,
              value.count <= 256 else { return nil }
        return value
    }
}

struct SessionCopyRelationship: Equatable {
    let sourceThreadID: String
    let targetThreadID: String
    let evidence: SessionOriginEvidence
}

enum SessionRelationshipResolver {
    static func relationship(
        in targetPreview: SessionCopyPreview,
        observedAt: Date = Date()
    ) -> SessionCopyRelationship? {
        for message in targetPreview.messages where message.role == "user" {
            guard let sourceThreadID = SessionCopyMarker.sourceThreadID(
                in: message.text
            ),
                  sourceThreadID != targetPreview.sourceThreadID else {
                continue
            }
            return SessionCopyRelationship(
                sourceThreadID: sourceThreadID,
                targetThreadID: targetPreview.sourceThreadID,
                evidence: SessionOriginEvidence(
                    kind: .userConfirmation,
                    source: "用户授权读取的可见复制标记",
                    value: "source=\(sourceThreadID);target=\(targetPreview.sourceThreadID)",
                    observedAt: observedAt
                )
            )
        }
        return nil
    }
}

struct RolloutVisibleTranscriptExtractor {
    let reader: RolloutSessionReader

    init(reader: RolloutSessionReader = RolloutSessionReader()) {
        self.reader = reader
    }

    func preview(
        at url: URL,
        threadID: String,
        authorization: SessionReadAuthorization
    ) throws -> SessionCopyPreview {
        guard authorization.metadataAllowed, authorization.visibleBodyAllowed else {
            throw SessionCenterError.authorizationRequired
        }
        try reader.validate(url)
        var messages: [SessionVisibleMessage] = []
        var attachments = 0
        var encrypted = false
        var continuationFailure: SessionContinuationFailure?
        var turnOutcome = SessionTurnOutcomeTracker()
        var excluded = Set<String>(["系统指令", "隐藏推理", "响应ID", "工具私有状态", "凭据"])
        try reader.forEachLine(at: url) { data in
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            turnOutcome.observe(object)
            if containsKey("encrypted_content", in: object) {
                encrypted = true
                excluded.insert("encrypted_content")
            }
            if continuationFailure == nil,
               let detected = detectContinuationFailure(
                   in: object
               ) {
                continuationFailure = detected
                excluded.insert(detected.excludedCategory)
            }
            guard let payload = object["payload"] as? [String: Any] else { return }
            let role = (payload["role"] as? String)
                ?? ((payload["message"] as? [String: Any])?["role"] as? String)
            guard role == "user" || role == "assistant" else { return }
            let content = payload["content"] ?? (payload["message"] as? [String: Any])?["content"]
            let extracted = visibleText(from: content)
            attachments += extracted.attachments
            if extracted.attachments > 0 { excluded.insert("图片或附件") }
            let clean = redactCredentials(extracted.text)
            guard !clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            messages.append(SessionVisibleMessage(
                role: role!,
                text: clean,
                timestamp: timestamp(from: object)
            ))
        }
        if continuationFailure == nil,
           let detected = turnOutcome.continuationFailure {
            continuationFailure = detected
            excluded.insert(detected.excludedCategory)
        }
        guard !messages.isEmpty else { throw SessionCenterError.bodyUnavailable }
        messages.sort {
            switch ($0.timestamp, $1.timestamp) {
            case let (left?, right?): return left < right
            case (nil, nil): return false
            case (nil, _): return false
            case (_, nil): return true
            }
        }
        return SessionCopyPreview(
            sourceThreadID: threadID,
            messages: messages,
            attachmentCount: attachments,
            excludedCategories: excluded.sorted(),
            containsEncryptedContent: encrypted,
            continuationFailure: continuationFailure
        )
    }

    func detectContinuationFailure(
        in object: [String: Any]
    ) -> SessionContinuationFailure? {
        guard object["type"] as? String == "response_item",
              let payload = object["payload"] as? [String: Any],
              payload["type"] as? String
                == "custom_tool_call_output" else {
            return nil
        }
        if containsGitMetadataPermissionDeniedSignature(in: payload) {
            return .gitMetadataPermissionDenied
        }
        guard containsContinuationFailureSignature(in: payload) else {
            return nil
        }
        return .encryptedToolOutputDecodeFailure
    }

    private func containsGitMetadataPermissionDeniedSignature(
        in value: Any
    ) -> Bool {
        if let text = value as? String {
            return text.contains("Unable to create ")
                && text.contains("index.lock")
                && (
                    text.contains("Operation not permitted")
                        || text.contains("Read-only file system")
                )
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains {
                containsGitMetadataPermissionDeniedSignature(in: $0)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsGitMetadataPermissionDeniedSignature(in: $0)
            }
        }
        return false
    }

    private func containsContinuationFailureSignature(
        in value: Any
    ) -> Bool {
        if let text = value as? String {
            return text.contains(
                "Encrypted function output content could not be decrypted or decoded."
            ) || text.contains("invalid_encrypted_content")
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains {
                containsContinuationFailureSignature(in: $0)
            }
        }
        if let array = value as? [Any] {
            return array.contains {
                containsContinuationFailureSignature(in: $0)
            }
        }
        return false
    }

    func visibleText(from value: Any?) -> (text: String, attachments: Int) {
        if let text = value as? String { return (text, 0) }
        guard let items = value as? [[String: Any]] else { return ("", 0) }
        var texts: [String] = []
        var attachments = 0
        for item in items {
            let type = item["type"] as? String ?? ""
            if ["input_text", "output_text", "text"].contains(type),
               let text = item["text"] as? String {
                texts.append(text)
            } else if type.contains("image") || type.contains("file") || type.contains("attachment") {
                attachments += 1
            }
        }
        return (texts.joined(separator: "\n"), attachments)
    }

    func containsKey(_ key: String, in value: Any) -> Bool {
        if let dictionary = value as? [String: Any] {
            if dictionary[key] != nil { return true }
            return dictionary.values.contains { containsKey(key, in: $0) }
        }
        if let array = value as? [Any] {
            return array.contains { containsKey(key, in: $0) }
        }
        return false
    }

    func timestamp(from object: [String: Any]) -> Date? {
        guard let raw = object["timestamp"] as? String else { return nil }
        return ISO8601DateFormatter.sessionCenter.date(from: raw)
    }

    func redactCredentials(_ text: String) -> String {
        var output = text
        let patterns = [
            #"(?i)\b(sk|rk|pk)-[A-Za-z0-9_-]{12,}\b"#,
            #"(?i)\b(api[_-]?key|authorization|bearer)\s*[:=]\s*[^\s,;]+"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            output = regex.stringByReplacingMatches(
                in: output,
                range: NSRange(output.startIndex..., in: output),
                withTemplate: "【凭据已遮挡】"
            )
        }
        return output
    }
}

enum SessionContinuationCapability: String, Codable {
    case automaticOpen
    case switchOnly
    case blocked
}

struct CodexDesktopSessionOpenDecision: Equatable {
    let allowed: Bool
    let requiresOriginConfirmation: Bool
    let reason: String
    let url: URL?
}

enum CodexDesktopSessionLink {
    static func url(threadID: String) -> URL? {
        guard let uuid = UUID(uuidString: threadID),
              uuid.uuidString.caseInsensitiveCompare(threadID) == .orderedSame else {
            return nil
        }
        var components = URLComponents()
        components.scheme = "codex"
        components.host = "threads"
        components.path = "/\(uuid.uuidString.lowercased())"
        return components.url
    }

    static func decision(
        session: SessionOrigin,
        currentProvider: String?,
        runtimeTruthVerified: Bool,
        userConfirmedOrigin: Bool
    ) -> CodexDesktopSessionOpenDecision {
        guard runtimeTruthVerified else {
            return CodexDesktopSessionOpenDecision(
                allowed: false,
                requiresOriginConfirmation: false,
                reason: "尚未取得可信的当前运行轨，请先到配置档页面重新核对。",
                url: nil
            )
        }
        guard let origin = normalizedProvider(session.observedProvider) else {
            return CodexDesktopSessionOpenDecision(
                allowed: false,
                requiresOriginConfirmation: false,
                reason: "该会话没有原轨证据，不能直接续聊。",
                url: nil
            )
        }
        let current = normalizedProvider(currentProvider) ?? "openai"
        guard current == origin else {
            return CodexDesktopSessionOpenDecision(
                allowed: false,
                requiresOriginConfirmation: false,
                reason: "当前轨是\(current)，会话原轨是\(origin)；请先安全切回原轨。",
                url: nil
            )
        }
        let needsConfirmation =
            origin == "custom"
            || session.confidence == .unknown
            || session.confidence == .low
        guard !needsConfirmation || userConfirmedOrigin else {
            return CodexDesktopSessionOpenDecision(
                allowed: false,
                requiresOriginConfirmation: true,
                reason: "Provider名称不足以区分多个中转；请确认当前就是该会话原轨。",
                url: nil
            )
        }
        guard let url = url(threadID: session.threadID) else {
            return CodexDesktopSessionOpenDecision(
                allowed: false,
                requiresOriginConfirmation: false,
                reason: "Thread ID不是Codex Desktop可打开的标准UUID。",
                url: nil
            )
        }
        return CodexDesktopSessionOpenDecision(
            allowed: true,
            requiresOriginConfirmation: needsConfirmation,
            reason: "当前轨与原轨一致，可以在Codex Desktop打开原会话。",
            url: url
        )
    }

    private static func normalizedProvider(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return nil }
        if ["official", "chatgpt", "openai"].contains(normalized) {
            return "openai"
        }
        return normalized
    }
}

struct SessionContinuationPlan: Equatable {
    let threadID: String
    let originProvider: String?
    let requiresRailSwitch: Bool
    let capability: SessionContinuationCapability
    let instruction: String
}

enum SessionActionPlanner {
    static func continueOnOrigin(
        session: SessionOrigin,
        currentProvider: String?,
        hasStableOpenInterface: Bool
    ) -> SessionContinuationPlan {
        guard let origin = session.observedProvider else {
            return SessionContinuationPlan(
                threadID: session.threadID,
                originProvider: nil,
                requiresRailSwitch: false,
                capability: .blocked,
                instruction: "来源证据不足，不能自动切轨；请只读查看或手动选择来源。"
            )
        }
        return SessionContinuationPlan(
            threadID: session.threadID,
            originProvider: origin,
            requiresRailSwitch: currentProvider != origin,
            capability: hasStableOpenInterface ? .automaticOpen : .switchOnly,
            instruction: hasStableOpenInterface
                ? "当前轨与原轨一致后，通过Codex Desktop公开会话入口打开原会话；不写SQLite或rollout。"
                : "安全切到原轨后，在Codex会话列表中按Thread ID打开；助手不写SQLite或rollout。"
        )
    }
}

enum SessionSelectionResolver {
    static func selected(
        sessionID: String?,
        from sessions: [SessionOrigin]
    ) -> SessionOrigin? {
        guard let sessionID else { return nil }
        return sessions.first { $0.threadID == sessionID }
    }
}

private extension ISO8601DateFormatter {
    static let sessionCenter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
