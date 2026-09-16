import Foundation

struct V012RateLimitObservation: Codable, Equatable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date
    let observedAt: Date

    var isWeekly: Bool {
        windowMinutes >= 6 * 24 * 60
            && windowMinutes <= 8 * 24 * 60
    }

    /// Build182 R1：按 window_minutes 识别唯一有效周窗口，兼容
    /// rate_limits.primary 或 secondary。缺失或同时出现两个周窗口
    /// 均视为歧义，fail closed 返回 nil。
    static func weekly(
        fromPrimary primary: V012RateLimitObservation?,
        secondary: V012RateLimitObservation?
    ) -> V012RateLimitObservation? {
        let weekly = [primary, secondary].compactMap { $0 }
            .filter { $0.isWeekly }
        guard weekly.count == 1 else { return nil }
        return weekly[0]
    }
}

struct V012UpstreamTokenUsage: Codable, Equatable, Sendable {
    let observedAt: Date
    let inputTokens: Int64
    let cachedInputTokens: Int64
    let cacheWriteInputTokens: Int64?
    let outputTokens: Int64
    let reasoningOutputTokens: Int64
    let activeContextTokens: Int64?
    let rateLimit: V012RateLimitObservation?
    let creditBalance: String?

    var uncachedInputTokens: Int64? {
        guard let cacheWriteInputTokens else { return nil }
        return max(
            0,
            inputTokens
                - cachedInputTokens
                - cacheWriteInputTokens
        )
    }

    var isStructurallyValid: Bool {
        [
            inputTokens,
            cachedInputTokens,
            outputTokens,
            reasoningOutputTokens,
        ].allSatisfy { $0 >= 0 }
            && cacheWriteInputTokens.map { value in
                value >= 0
                    && cachedInputTokens + value <= inputTokens
            } != false
            && activeContextTokens.map { $0 >= 0 } != false
            && reasoningOutputTokens <= outputTokens
            && creditBalance.map {
                V012ModelTokenRate.safeText(
                    $0,
                    maximumBytes: 80
                )
            } != false
    }
}

struct V012CompletedTurnUsage: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let startedAt: Date
    let completedAt: Date
    let durationMilliseconds: Int64?
    let timeToFirstTokenMilliseconds: Int64?
    let model: String
    let providerID: String
    let serviceTier: String?
    let calls: [V012UpstreamTokenUsage]
    /// Exec's final usage is a turn total, not a single upstream request.
    var containsOnlyTurnTotals: Bool? = nil
    /// The raw ID is only retained in memory for the follow-up official read.
    var sourceThreadID: String? = nil
    var sourceThreadIDHash: String? = nil
    var officialRequestPricing: V012OfficialRequestPricingEvidence? = nil

    private enum CodingKeys: String, CodingKey {
        case id, startedAt, completedAt, durationMilliseconds, timeToFirstTokenMilliseconds
        case model, providerID, serviceTier, calls, containsOnlyTurnTotals
        case sourceThreadIDHash, officialRequestPricing
    }

    var inputTokens: Int64 {
        calls.reduce(0) { $0 + $1.inputTokens }
    }

    var cachedInputTokens: Int64 {
        calls.reduce(0) { $0 + $1.cachedInputTokens }
    }

    var cacheWriteInputTokens: Int64? {
        guard calls.allSatisfy({ $0.cacheWriteInputTokens != nil }) else {
            return nil
        }
        return calls.reduce(0) {
            $0 + ($1.cacheWriteInputTokens ?? 0)
        }
    }

    var uncachedInputTokens: Int64? {
        guard calls.allSatisfy({ $0.uncachedInputTokens != nil }) else {
            return nil
        }
        return calls.reduce(0) {
            $0 + ($1.uncachedInputTokens ?? 0)
        }
    }

    var outputTokens: Int64 {
        calls.reduce(0) { $0 + $1.outputTokens }
    }

    var reasoningOutputTokens: Int64 {
        calls.reduce(0) { $0 + $1.reasoningOutputTokens }
    }

    var modelProcessedTokens: Int64 {
        inputTokens + outputTokens
    }

    var activeContextTokens: Int64? {
        calls.last?.activeContextTokens
    }
}

struct V012UsageReadResult: Equatable, Sendable {
    let turns: [V012CompletedTurnUsage]
    let sourceChangedDuringRead: Bool
    let overflowed: Bool

    init(
        turns: [V012CompletedTurnUsage],
        sourceChangedDuringRead: Bool,
        overflowed: Bool = false
    ) {
        self.turns = turns
        self.sourceChangedDuringRead = sourceChangedDuringRead
        self.overflowed = overflowed
    }
}

enum V012RolloutUsageError: LocalizedError {
    case malformedUsage

    var errorDescription: String? {
        "请求用量记录格式无法安全识别"
    }
}
