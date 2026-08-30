import Foundation

extension V011OfficialUsageReading {
    func read(threadID: String) throws -> V011OfficialUsageSnapshot {
        _ = threadID
        return try read()
    }
}

private enum V011OfficialUsageValue {
    static func safeText(
        _ value: String,
        maximumBytes: Int,
        allowEmpty: Bool = false
    ) -> Bool {
        (allowEmpty || !value.isEmpty)
            && value.utf8.count <= maximumBytes
            && !value.unicodeScalars.contains {
                CharacterSet.controlCharacters.contains($0)
            }
    }

    static func optionalText(
        _ value: Any?,
        maximumBytes: Int
    ) throws -> String? {
        guard let value, !(value is NSNull) else { return nil }
        guard let text = value as? String,
              safeText(text, maximumBytes: maximumBytes) else {
            throw V011OfficialUsageError.protocolMismatch
        }
        return text
    }

    static func requiredNonnegativeInteger(
        _ value: Any?
    ) throws -> Int64 {
        guard let number = value as? NSNumber else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let doubleValue = number.doubleValue
        guard doubleValue.isFinite,
              doubleValue.rounded() == doubleValue,
              doubleValue >= 0,
              doubleValue <= Double(Int64.max) else {
            throw V011OfficialUsageError.protocolMismatch
        }
        return number.int64Value
    }

    static func optionalNonnegativeInteger(
        _ object: [String: Any],
        key: String
    ) throws -> Int64? {
        guard let value = object[key], !(value is NSNull) else {
            return nil
        }
        return try requiredNonnegativeInteger(value)
    }
}

struct V011OfficialCreditsSnapshot: Codable, Equatable {
    let balance: String?
    let hasCredits: Bool
    let unlimited: Bool

    var isStructurallyValid: Bool {
        balance.map {
            V011OfficialUsageValue.safeText(
                $0,
                maximumBytes: 80
            )
        } != false
    }

    var displayText: String {
        if unlimited { return "已购 credits：无限" }
        if let balance { return "已购 credits：\(balance)" }
        return hasCredits
            ? "已购 credits：有，余额未返回"
            : "已购 credits：无"
    }

    static func parse(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              let hasCredits = object["hasCredits"] as? Bool,
              let unlimited = object["unlimited"] as? Bool else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let snapshot = Self(
            balance: try V011OfficialUsageValue.optionalText(
                object["balance"],
                maximumBytes: 80
            ),
            hasCredits: hasCredits,
            unlimited: unlimited
        )
        guard snapshot.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return snapshot
    }
}

struct V011OfficialSpendControlSnapshot: Codable, Equatable {
    let limit: String
    let used: String
    let remainingPercent: Int
    let resetsAt: Date

    var isStructurallyValid: Bool {
        V011OfficialUsageValue.safeText(limit, maximumBytes: 80)
            && V011OfficialUsageValue.safeText(
                used,
                maximumBytes: 80
            )
            && (0...100).contains(remainingPercent)
            && resetsAt.timeIntervalSince1970.isFinite
            && resetsAt.timeIntervalSince1970 > 0
    }

    static func parse(_ value: Any?) throws -> Self? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              let limit = try V011OfficialUsageValue.optionalText(
                  object["limit"],
                  maximumBytes: 80
              ),
              let used = try V011OfficialUsageValue.optionalText(
                  object["used"],
                  maximumBytes: 80
              ) else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let remaining = try V011OfficialUsageValue
            .requiredNonnegativeInteger(object["remainingPercent"])
        let reset = try V011OfficialUsageValue
            .requiredNonnegativeInteger(object["resetsAt"])
        guard let remainingPercent = Int(exactly: remaining) else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let snapshot = Self(
            limit: limit,
            used: used,
            remainingPercent: remainingPercent,
            resetsAt: Date(timeIntervalSince1970: TimeInterval(reset))
        )
        guard snapshot.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return snapshot
    }
}

struct V011OfficialAccountUsageSummary: Codable, Equatable {
    let lifetimeTokens: Int64?
    let currentStreakDays: Int64?
    let longestStreakDays: Int64?
    let peakDailyTokens: Int64?
    let longestRunningTurnSeconds: Int64?

    var isStructurallyValid: Bool {
        [
            lifetimeTokens,
            currentStreakDays,
            longestStreakDays,
            peakDailyTokens,
            longestRunningTurnSeconds,
        ].allSatisfy { $0.map { $0 >= 0 } != false }
    }

    var displayText: String {
        if let lifetimeTokens {
            return "账户 token 活动：累计 \(lifetimeTokens.formatted())"
        }
        if let peakDailyTokens {
            return "账户 token 活动：单日峰值 \(peakDailyTokens.formatted())"
        }
        return "账户 token 活动：官方未返回数值"
    }
}

struct V011OfficialDailyUsageBucket: Codable, Equatable {
    let startDate: String
    let tokens: Int64

    var isStructurallyValid: Bool {
        V011OfficialUsageValue.safeText(
            startDate,
            maximumBytes: 32
        ) && tokens >= 0
    }
}

struct V011OfficialThreadUsageGroup: Codable, Equatable {
    let model: String?
    let reasoningEffort: String?
    let speed: String?
    let inputTokens: Int64?
    let cachedInputTokens: Int64?
    let netNewInputTokens: Int64?
    let outputTokens: Int64?
    let totalTokens: Int64?
    let estimatedUsageCreditsMicros: Int64

    var isStructurallyValid: Bool {
        [model, reasoningEffort, speed].allSatisfy {
            $0.map {
                V011OfficialUsageValue.safeText(
                    $0,
                    maximumBytes: 128
                )
            } != false
        }
            && [
                inputTokens,
                cachedInputTokens,
                netNewInputTokens,
                outputTokens,
                totalTokens,
            ].allSatisfy { $0.map { $0 >= 0 } != false }
            && estimatedUsageCreditsMicros >= 0
    }
}

struct V011OfficialThreadUsage: Codable, Equatable {
    let threadScopeSHA256: String
    let estimatedUsageCreditsMicros: Int64
    let estimatedUsageUSDMicros: Int64?
    let groups: [V011OfficialThreadUsageGroup]

    var isStructurallyValid: Bool {
        threadScopeSHA256.count == 64
            && threadScopeSHA256.allSatisfy {
                $0.isHexDigit && !$0.isUppercase
            }
            && estimatedUsageCreditsMicros >= 0
            && estimatedUsageUSDMicros.map { $0 >= 0 } != false
            && groups.count <= 128
            && groups.allSatisfy(\.isStructurallyValid)
    }
}

struct V011OfficialTokenUsageSnapshot: Codable, Equatable {
    let summary: V011OfficialAccountUsageSummary
    let dailyUsageBuckets: [V011OfficialDailyUsageBucket]?
    let threadUsage: V011OfficialThreadUsage?

    var isStructurallyValid: Bool {
        summary.isStructurallyValid
            && dailyUsageBuckets.map {
                $0.count <= 400
                    && $0.allSatisfy(\.isStructurallyValid)
            } != false
            && threadUsage.map(\.isStructurallyValid) != false
    }

    static func parse(
        accountResult: [String: Any],
        threadResult: [String: Any]?,
        requestedThreadID: String?
    ) throws -> Self {
        guard let rawSummary = accountResult["summary"]
                as? [String: Any] else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let summary = V011OfficialAccountUsageSummary(
            lifetimeTokens: try V011OfficialUsageValue
                .optionalNonnegativeInteger(
                    rawSummary,
                    key: "lifetimeTokens"
                ),
            currentStreakDays: try V011OfficialUsageValue
                .optionalNonnegativeInteger(
                    rawSummary,
                    key: "currentStreakDays"
                ),
            longestStreakDays: try V011OfficialUsageValue
                .optionalNonnegativeInteger(
                    rawSummary,
                    key: "longestStreakDays"
                ),
            peakDailyTokens: try V011OfficialUsageValue
                .optionalNonnegativeInteger(
                    rawSummary,
                    key: "peakDailyTokens"
                ),
            longestRunningTurnSeconds: try V011OfficialUsageValue
                .optionalNonnegativeInteger(
                    rawSummary,
                    key: "longestRunningTurnSec"
                )
        )
        let dailyUsageBuckets = try parseDailyBuckets(
            accountResult["dailyUsageBuckets"]
        )
        let threadUsage = try parseThreadUsage(
            threadResult?["threadUsage"]
                ?? accountResult["threadUsage"],
            requestedThreadID: requestedThreadID
        )
        let snapshot = Self(
            summary: summary,
            dailyUsageBuckets: dailyUsageBuckets,
            threadUsage: threadUsage
        )
        guard snapshot.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return snapshot
    }

    private static func parseDailyBuckets(
        _ value: Any?
    ) throws -> [V011OfficialDailyUsageBucket]? {
        guard let value, !(value is NSNull) else { return nil }
        guard let rows = value as? [[String: Any]],
              rows.count <= 400 else {
            throw V011OfficialUsageError.protocolMismatch
        }
        return try rows.map { row in
            guard let startDate = try V011OfficialUsageValue
                    .optionalText(
                        row["startDate"],
                        maximumBytes: 32
                    ) else {
                throw V011OfficialUsageError.protocolMismatch
            }
            return V011OfficialDailyUsageBucket(
                startDate: startDate,
                tokens: try V011OfficialUsageValue
                    .requiredNonnegativeInteger(row["tokens"])
            )
        }
    }

    private static func parseThreadUsage(
        _ value: Any?,
        requestedThreadID: String?
    ) throws -> V011OfficialThreadUsage? {
        guard let value, !(value is NSNull) else { return nil }
        guard let object = value as? [String: Any],
              let threadID = try V011OfficialUsageValue.optionalText(
                  object["threadId"],
                  maximumBytes: 512
              ),
              requestedThreadID.map({ $0 == threadID }) != false,
              let rawGroups = object["groups"]
                as? [[String: Any]],
              rawGroups.count <= 128 else {
            throw V011OfficialUsageError.protocolMismatch
        }
        let groups = try rawGroups.map { group in
            let value = V011OfficialThreadUsageGroup(
                model: try V011OfficialUsageValue.optionalText(
                    group["model"],
                    maximumBytes: 128
                ),
                reasoningEffort: try V011OfficialUsageValue
                    .optionalText(
                        group["reasoningEffort"],
                        maximumBytes: 128
                    ),
                speed: try V011OfficialUsageValue.optionalText(
                    group["speed"],
                    maximumBytes: 128
                ),
                inputTokens: try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        group,
                        key: "inputTokens"
                    ),
                cachedInputTokens: try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        group,
                        key: "cachedInputTokens"
                    ),
                netNewInputTokens: try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        group,
                        key: "netNewInputTokens"
                    ),
                outputTokens: try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        group,
                        key: "outputTokens"
                    ),
                totalTokens: try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        group,
                        key: "totalTokens"
                    ),
                estimatedUsageCreditsMicros:
                    try V011OfficialUsageValue
                        .requiredNonnegativeInteger(
                            group["estimatedUsageCreditsMicros"]
                        )
            )
            guard value.isStructurallyValid else {
                throw V011OfficialUsageError.unsafeEvidence
            }
            return value
        }
        let usage = V011OfficialThreadUsage(
            threadScopeSHA256: V011AgentLoopReceipt.sha256(
                Data(threadID.utf8)
            ),
            estimatedUsageCreditsMicros:
                try V011OfficialUsageValue
                    .requiredNonnegativeInteger(
                        object["estimatedUsageCreditsMicros"]
                    ),
            estimatedUsageUSDMicros:
                try V011OfficialUsageValue
                    .optionalNonnegativeInteger(
                        object,
                        key: "estimatedUsageUsdMicros"
                    ),
            groups: groups
        )
        guard usage.isStructurallyValid else {
            throw V011OfficialUsageError.unsafeEvidence
        }
        return usage
    }
}

struct V011UnifiedResourceItem: Identifiable, Equatable {
    enum Kind: Equatable { case official, savedRelay }

    let id: String
    let kind: Kind
    let name: String
    let isCurrent: Bool
    let availability: String
    let balance: String
    let planAllowance: String
    let accountActivity: String
    let spendControl: String
    let evidenceSource: String
    let refreshedAt: Date?
    let modelCompatibility: String
    let contextCompatibility: String
}

extension V011AccessModel {
    func unifiedResourceOverview(
        maximumSavedRelays: Int? = nil
    ) -> [V011UnifiedResourceItem] {
        var items = [officialResourceOverviewItem()]
        var profiles = savedProfiles
        if case let .relay(providerID)? = liveState?.mode,
           let currentIndex = profiles.firstIndex(where: {
               $0.v011ProviderID == providerID
           }), currentIndex != profiles.startIndex {
            profiles.insert(profiles.remove(at: currentIndex), at: 0)
        }
        if let maximumSavedRelays {
            profiles = Array(profiles.prefix(max(0, maximumSavedRelays)))
        }
        items.append(contentsOf: profiles.map(relayResourceOverviewItem))
        return items
    }

    private func officialResourceOverviewItem()
        -> V011UnifiedResourceItem {
        let isCurrent: Bool
        if case .official? = liveState?.mode {
            isCurrent = true
        } else {
            isCurrent = false
        }
        let availability: String
        if isCurrent && isAgentLoopVerified {
            availability = "真实任务可用"
        } else if isCurrent && isCurrentConnectionVerified {
            availability = "基础连接可用；真实任务未验证"
        } else if isCurrent {
            availability = "当前已选择；可用性未验证"
        } else if liveState == nil {
            availability = "当前状态未读取"
        } else {
            availability = "当前未使用；官方可用性未知"
        }
        let snapshot = officialUsageSnapshot
        let allowance = snapshot?.windows.map {
            "\($0.displayName)已用 \($0.usedPercent)% / 剩余 \($0.remainingPercent)%"
                + ($0.resetsAt.map {
                    "，重置 \($0.formatted(date: .abbreviated, time: .shortened))"
                } ?? "，重置时间未知")
        }.joined(separator: " · ")
        let spendControl: String
        if snapshot?.spendControlReached == true {
            spendControl = "官方报告：用量控制已达上限"
        } else if let individual = snapshot?.individualLimit {
            spendControl =
                "个人用量控制剩余 \(individual.remainingPercent)%"
        } else if snapshot?.spendControlReached == false {
            spendControl = "官方报告：未触发个人用量控制"
        } else if let reached = snapshot?.rateLimitReachedType {
            spendControl = "官方限制状态：\(reached)"
        } else {
            spendControl = "用量控制状态未知"
        }
        let modelText: String
        let contextText: String
        if isCurrent, let liveState {
            modelText = liveState.model.map {
                "当前官方模型：\($0)"
            } ?? "当前官方模型：由 Codex 动态决定"
            if let context = liveState.contextWindow {
                let compact = liveState.autoCompactTokenLimit.map {
                    "；自动压缩 \($0.formatted())"
                } ?? ""
                contextText =
                    "当前配置上下文 \(context.formatted()) tokens\(compact)"
            } else {
                contextText = "当前官方上下文上限未知"
            }
        } else {
            modelText = "官方模型兼容性：当前未使用，未知"
            contextText = "官方上下文兼容性：当前未使用，未知"
        }
        let evidence: String
        if snapshot?.tokenUsage != nil {
            evidence =
                "Codex app-server：rateLimits + usage 只读回执"
        } else if snapshot != nil {
            evidence =
                "Codex app-server：rateLimits 只读回执；token 活动未知"
        } else {
            evidence = "尚无 Codex app-server 官方资源回执"
        }
        return V011UnifiedResourceItem(
            id: "official",
            kind: .official,
            name: "Codex 官方",
            isCurrent: isCurrent,
            availability: availability,
            balance: snapshot?.credits?.displayText
                ?? "已购 credits：未知",
            planAllowance: allowance?.isEmpty == false
                ? "套餐 \(snapshot?.planType ?? "未知") · 套餐额度：\(allowance!)"
                : "套餐额度：未知",
            accountActivity: snapshot?.tokenUsage?.summary.displayText
                ?? "账户 token 活动：未知",
            spendControl: spendControl,
            evidenceSource: evidence,
            refreshedAt: snapshot?.observedAt,
            modelCompatibility: modelText,
            contextCompatibility: contextText
        )
    }

    private func relayResourceOverviewItem(
        _ profile: CodexRelayProfile
    ) -> V011UnifiedResourceItem {
        let isCurrent: Bool
        if case let .relay(providerID)? = liveState?.mode {
            isCurrent = providerID == profile.v011ProviderID
        } else {
            isCurrent = false
        }
        let receipt = savedRelayReadinessReceipts[profile.id]
        let evidence = receipt == nil
            ? "本机已保存资料；无余额接口或真实任务回执"
            : "本机已保存资料 + 隔离真实任务回执"
        let context: String
        if let window = profile.contextWindow {
            let compact = profile.autoCompactTokenLimit.map {
                "；自动压缩 \($0.formatted())"
            } ?? ""
            context =
                "已保存上下文 \(window.formatted()) tokens\(compact)"
        } else {
            context = "上下文兼容性：已保存资料未写明"
        }
        return V011UnifiedResourceItem(
            id: "relay:\(profile.id)",
            kind: .savedRelay,
            name: profile.name,
            isCurrent: isCurrent,
            availability: savedRelayReadinessStatus(for: profile),
            balance: "中转余额：未知（无文档化只读接口）",
            planAllowance: "中转套餐额度：未知",
            accountActivity: "中转 token 活动：未知",
            spendControl: "中转用量控制：未知",
            evidenceSource: evidence,
            refreshedAt: receipt?.observedAt,
            modelCompatibility:
                "默认模型：\(profile.defaultModel) · 已保存 \(profile.models.count) 个模型",
            contextCompatibility: context
        )
    }
}
