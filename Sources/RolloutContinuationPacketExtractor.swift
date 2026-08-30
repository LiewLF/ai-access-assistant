// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Reads every rollout line while retaining only candidates that can enter
/// the bounded continuation packet. Full visible transcript previews keep
/// using RolloutVisibleTranscriptExtractor.preview().
struct RolloutContinuationPacketExtractor {
    let reader: RolloutSessionReader
    private let visibleExtractor: RolloutVisibleTranscriptExtractor

    init(reader: RolloutSessionReader = RolloutSessionReader()) {
        self.reader = reader
        visibleExtractor = RolloutVisibleTranscriptExtractor(
            reader: reader
        )
    }

    func packet(
        at url: URL,
        threadID: String,
        authorization: SessionReadAuthorization,
        policy: SessionContinuationPacketPolicy = .default
    ) throws -> SessionContinuationPacket {
        guard authorization.metadataAllowed,
              authorization.visibleBodyAllowed else {
            throw SessionCenterError.authorizationRequired
        }
        try reader.validate(url)
        var collector = BoundedContinuationCollector(policy: policy)
        var attachments = 0
        var encrypted = false
        var continuationFailure: SessionContinuationFailure?
        var turnOutcome = SessionTurnOutcomeTracker()
        var excluded = Set<String>([
            "系统指令", "隐藏推理", "响应ID", "工具私有状态", "凭据",
        ])

        try reader.forEachLine(at: url) { data in
            guard let object = try? JSONSerialization
                .jsonObject(with: data) as? [String: Any] else {
                return
            }
            turnOutcome.observe(object)
            if visibleExtractor.containsKey(
                "encrypted_content",
                in: object
            ) {
                encrypted = true
                excluded.insert("encrypted_content")
            }
            if continuationFailure == nil,
               let detected = visibleExtractor
                .detectContinuationFailure(in: object) {
                continuationFailure = detected
                excluded.insert(detected.excludedCategory)
            }
            guard let payload = object["payload"]
                as? [String: Any] else {
                return
            }
            let role = (payload["role"] as? String)
                ?? ((payload["message"] as? [String: Any])?["role"]
                    as? String)
            guard let role,
                  role == "user" || role == "assistant" else {
                return
            }
            let content = payload["content"]
                ?? (payload["message"] as? [String: Any])?["content"]
            let extracted = visibleExtractor.visibleText(from: content)
            attachments += extracted.attachments
            if extracted.attachments > 0 {
                excluded.insert("图片或附件")
            }
            let clean = visibleExtractor
                .redactCredentials(extracted.text)
            guard !clean.trimmingCharacters(
                in: .whitespacesAndNewlines
            ).isEmpty else {
                return
            }
            collector.append(
                role: role,
                text: clean,
                timestamp: visibleExtractor.timestamp(from: object)
            )
        }

        if continuationFailure == nil,
           let detected = turnOutcome.continuationFailure {
            continuationFailure = detected
            excluded.insert(detected.excludedCategory)
        }
        guard collector.messageCount > 0 else {
            throw SessionCenterError.bodyUnavailable
        }
        return collector.packet(
            sourceThreadID: threadID,
            attachmentCount: attachments,
            excludedCategories: excluded.sorted(),
            containsEncryptedContent: encrypted,
            continuationFailure: continuationFailure
        )
    }
}

private struct BoundedContinuationCandidate {
    let sequence: Int
    let role: String
    let retainedText: String
    let originalCharacterCount: Int
    let timestamp: Date?

    func isEarlier(than other: Self) -> Bool {
        switch (timestamp, other.timestamp) {
        case let (left?, right?):
            if left != right { return left < right }
            return sequence < other.sequence
        case (nil, nil):
            return sequence < other.sequence
        case (nil, _):
            return false
        case (_, nil):
            return true
        }
    }
}

private struct BoundedContinuationCollector {
    let policy: SessionContinuationPacketPolicy
    private(set) var messageCount = 0
    private var firstUser: BoundedContinuationCandidate?
    private var recentUsers: [BoundedContinuationCandidate] = []
    private var recentMessages: [BoundedContinuationCandidate] = []

    init(policy: SessionContinuationPacketPolicy) {
        self.policy = policy
    }

    mutating func append(
        role: String,
        text: String,
        timestamp: Date?
    ) {
        let candidate = BoundedContinuationCandidate(
            sequence: messageCount,
            role: role,
            retainedText: String(
                text.prefix(policy.maximumCharactersPerMessage)
            ),
            originalCharacterCount: text.count,
            timestamp: timestamp
        )
        messageCount += 1
        if role == "user" {
            if let existing = firstUser {
                if candidate.isEarlier(than: existing) {
                    firstUser = candidate
                }
            } else {
                firstUser = candidate
            }
            recentUsers = Self.retainingLatest(
                recentUsers,
                adding: candidate,
                limit: policy.prioritizedRecentUserMessages
            )
        }
        // The latest maximumMessages entries are sufficient for fallback:
        // every prioritized entry inside this window also consumes one slot.
        recentMessages = Self.retainingLatest(
            recentMessages,
            adding: candidate,
            limit: policy.maximumMessages
        )
    }

    func packet(
        sourceThreadID: String,
        attachmentCount: Int,
        excludedCategories: [String],
        containsEncryptedContent: Bool,
        continuationFailure: SessionContinuationFailure?
    ) -> SessionContinuationPacket {
        var priority: [BoundedContinuationCandidate] = []
        var prioritizedSequences = Set<Int>()
        func appendPriority(
            _ candidate: BoundedContinuationCandidate
        ) {
            guard prioritizedSequences
                .insert(candidate.sequence).inserted else {
                return
            }
            priority.append(candidate)
        }
        if let firstUser {
            appendPriority(firstUser)
        }
        for candidate in recentUsers.sorted(by: Self.isLater) {
            appendPriority(candidate)
        }
        for candidate in recentMessages.sorted(by: Self.isLater) {
            appendPriority(candidate)
        }
        priority = Array(priority.prefix(policy.maximumMessages))

        var remainingCharacters = policy.maximumTotalCharacters
        var selected: [(
            candidate: BoundedContinuationCandidate,
            message: SessionVisibleMessage
        )] = []
        var truncatedMessageCount = 0
        for candidate in priority where remainingCharacters > 0 {
            let characterLimit = min(
                policy.maximumCharactersPerMessage,
                remainingCharacters
            )
            let text = String(
                candidate.retainedText.prefix(characterLimit)
            )
            guard !text.isEmpty else { continue }
            if text.count < candidate.originalCharacterCount {
                truncatedMessageCount += 1
            }
            selected.append((
                candidate: candidate,
                message: SessionVisibleMessage(
                    role: candidate.role,
                    text: text,
                    timestamp: candidate.timestamp
                )
            ))
            remainingCharacters -= text.count
        }
        let messages = selected.sorted {
            $0.candidate.isEarlier(than: $1.candidate)
        }.map(\.message)
        return SessionContinuationPacket(
            sourceThreadID: sourceThreadID,
            messages: messages,
            omittedMessageCount: max(
                0,
                messageCount - messages.count
            ),
            truncatedMessageCount: truncatedMessageCount,
            attachmentCount: attachmentCount,
            excludedCategories: excludedCategories,
            containsEncryptedContent: containsEncryptedContent,
            continuationFailure: continuationFailure,
            policy: policy
        )
    }

    private static func retainingLatest(
        _ candidates: [BoundedContinuationCandidate],
        adding candidate: BoundedContinuationCandidate,
        limit: Int
    ) -> [BoundedContinuationCandidate] {
        let ordered = (candidates + [candidate]).sorted {
            $0.isEarlier(than: $1)
        }
        return Array(ordered.suffix(limit))
    }

    private static func isLater(
        _ left: BoundedContinuationCandidate,
        _ right: BoundedContinuationCandidate
    ) -> Bool {
        right.isEarlier(than: left)
    }
}
