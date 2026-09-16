import Foundation

struct V012PendingUsageRefresh {
    let rows: [V011SessionRow]
    let historyCoverage: V013UsageHistoryCoverage
    let officialSnapshot: V011OfficialUsageSnapshot?
    let profiles: [CodexRelayProfile]
}

struct V013ObservedWindowUsage: Equatable {
    let requestCount: Int
    let tokens: Int64
    let apiEquivalentUSD: Double?
    let observedFrom: Date
    let observedThrough: Date
    var credits: Double? = nil
    var pricingIssues: [String] = []
}

struct V013SupplementalUsageEvidence: Equatable {
    let observed: V013ObservedWindowUsage?
    let officialActivity: V013OfficialActivityEvidence?
    let currentEquivalentCapacity: V013EquivalentCapacityEvidence?
    let cpaQuota: V013CPAQuotaEvaluation
    let historicalEquivalentCapacity: V013EquivalentCapacityEvidence?
    let percentageTransitionCount: Int
    let usableIntervalCount: Int

    static let empty = Self(
        observed: nil,
        officialActivity: nil,
        currentEquivalentCapacity: nil,
        cpaQuota: .empty,
        historicalEquivalentCapacity: nil,
        percentageTransitionCount: 0,
        usableIntervalCount: 0
    )
}

struct V013OfficialActivityEvidence: Equatable {
    let latestDailyBucket: String?
    let latestDailyBucketTokens: Int64?
    let dailyBucketBoundaryKnown: Bool
    let localWindowTokens: Int64
    let localWindowIdentityBoundTokens: Int64
    let localWindowRequestCount: Int
    let windowStart: Date
    let observedThrough: Date
}

struct V013CPAQuotaEstimate: Equatable {
    let pointFullWindowTokens: Double
    let lowerFullWindowTokens: Double
    let upperFullWindowTokens: Double
    let pointFullWindowCredits: Double?
    let lowerFullWindowCredits: Double?
    let upperFullWindowCredits: Double?
    let pointFullWindowAPIEquivalentUSD: Double?
    let lowerFullWindowAPIEquivalentUSD: Double?
    let upperFullWindowAPIEquivalentUSD: Double?
    let observedTokens: Int64
    let observedCredits: Double?
    let observedAPIEquivalentUSD: Double?
    let percentSpan: Double
    let lastUsedPercent: Double
    let sampledFrom: Date
    let sampledThrough: Date
    let confidence: V013WeeklyUsageEstimate.Confidence
    let apiIntervalSampleCount: Int
    let creditsIntervalSampleCount: Int
}

struct V013CPAQuotaEvaluation: Equatable {
    let estimate: V013CPAQuotaEstimate?
    let partialCapacity: V013EquivalentCapacityEvidence?
    let reason: String
    let observationCount: Int
    let percentageTransitionCount: Int
    let usableIntervalCount: Int

    static let empty = Self(
        estimate: nil,
        partialCapacity: nil,
        reason: "正在积累可信样本：尚无同一周窗口的调用级配额样本",
        observationCount: 0,
        percentageTransitionCount: 0,
        usableIntervalCount: 0
    )
}

struct V013EquivalentCapacityEvidence: Equatable {
    enum Scope: String { case currentWindow, historicalWindow }
    enum Source: String {
        case officialAccountAlignedDelta
        case localIdentityBoundLowerBound
    }

    let scope: Scope
    let source: Source
    let lowerWeekTokens: Double
    let upperWeekTokens: Double?
    let observedTokenDelta: Int64
    let displayedPercentDelta: Int
    let sampledFrom: Date
    let sampledThrough: Date
    let resetsAt: Date
    let sampleCount: Int
}

enum V013UsageEvidenceBuilder {
    static func build(
        ledger: V013UsageLedgerState,
        snapshot: V011OfficialUsageSnapshot,
        window: V011OfficialUsageWindow,
        observations: [V013QuotaLedgerObservation],
        turns: [V012CompletedTurnUsage],
        historyCoverageComplete: Bool,
        sourceReadsStable: Bool,
        planType: String?,
        pricing: V013OfficialPricingSnapshot,
        apiPricingPolicy: V013APIPricingPolicy = .recordedTier
    ) -> V013SupplementalUsageEvidence {
        guard let resetsAt = window.resetsAt else { return .empty }
        let windowStart = resetsAt.addingTimeInterval(
            -Double(window.durationMinutes ?? 10_080) * 60
        )
        let observed = observedUsage(
            records: ledger.records,
            accountScope: snapshot.accountScopeSHA256,
            from: windowStart,
            through: snapshot.observedAt,
            planType: planType,
            pricing: pricing
        )
        let officialActivity = officialActivity(
            ledger: ledger,
            snapshot: snapshot,
            windowStart: windowStart
        )
        let officialCurrentEquivalent = equivalentCapacity(
            observations: observations,
            scope: .currentWindow
        )
        let cpaQuota = cpaQuotaEvaluation(
            records: ledger.records,
            turns: turns,
            observations: observations,
            accountScope: snapshot.accountScopeSHA256,
            windowStart: windowStart,
            resetsAt: resetsAt,
            observedThrough: snapshot.observedAt,
            historyCoverageComplete: historyCoverageComplete,
            sourceReadsStable: sourceReadsStable,
            planType: planType,
            pricing: pricing,
            apiPricingPolicy: apiPricingPolicy
        )
        let historicalEquivalent = historicalEquivalentCapacity(
            ledger: ledger,
            snapshot: snapshot,
            currentResetsAt: resetsAt
        )
        return V013SupplementalUsageEvidence(
            observed: observed,
            officialActivity: officialActivity,
            currentEquivalentCapacity: officialCurrentEquivalent
                ?? cpaQuota.partialCapacity,
            cpaQuota: cpaQuota,
            historicalEquivalentCapacity: historicalEquivalent,
            percentageTransitionCount:
                cpaQuota.percentageTransitionCount,
            usableIntervalCount: cpaQuota.usableIntervalCount
        )
    }

    private static func officialActivity(
        ledger: V013UsageLedgerState,
        snapshot: V011OfficialUsageSnapshot,
        windowStart: Date
    ) -> V013OfficialActivityEvidence? {
        let latest = (snapshot.tokenUsage?.dailyUsageBuckets ?? [])
            .filter { !$0.startDate.isEmpty && $0.tokens >= 0 }
            .sorted { $0.startDate < $1.startDate }
            .last
        let local = ledger.records.filter {
            isOfficial($0)
                && $0.completedAt >= windowStart
                && $0.completedAt <= snapshot.observedAt
        }
        let identityScope = snapshot.accountScopeSHA256
        guard latest != nil || !local.isEmpty else { return nil }
        return V013OfficialActivityEvidence(
            latestDailyBucket: latest?.startDate,
            latestDailyBucketTokens: latest?.tokens,
            dailyBucketBoundaryKnown: false,
            localWindowTokens: local.reduce(0) { $0 + $1.modelProcessedTokens },
            localWindowIdentityBoundTokens: local.filter {
                guard let identityScope else { return false }
                return $0.accountScopeSHA256 == identityScope
                    && $0.identityBoundAtCompletion
            }.reduce(0) { $0 + $1.modelProcessedTokens },
            localWindowRequestCount: local.count,
            windowStart: windowStart,
            observedThrough: snapshot.observedAt
        )
    }

    private static func equivalentCapacity(
        observations: [V013QuotaLedgerObservation],
        scope: V013EquivalentCapacityEvidence.Scope
    ) -> V013EquivalentCapacityEvidence? {
        let ordered = observations.sorted { $0.observedAt < $1.observedAt }
        var values: [V013EquivalentCapacityEvidence] = []
        for pair in zip(ordered, ordered.dropFirst()) {
            guard let firstTokens = pair.0.officialLifetimeTokens,
                  let lastTokens = pair.1.officialLifetimeTokens,
                  let firstCutoff = pair.0.officialUsageEffectiveThrough,
                  let lastCutoff = pair.1.officialUsageEffectiveThrough,
                  abs(firstCutoff.timeIntervalSince(pair.0.observedAt)) < 1,
                  abs(lastCutoff.timeIntervalSince(pair.1.observedAt)) < 1,
                  lastTokens > firstTokens,
                  pair.1.usedPercent >= pair.0.usedPercent else { continue }
            let displayedDelta = pair.1.usedPercent - pair.0.usedPercent
            let bounds = percentageDeltaBounds(
                from: pair.0.usedPercent,
                through: pair.1.usedPercent
            )
            guard bounds.maximum > 0 else { continue }
            let tokenDelta = lastTokens - firstTokens
            values.append(
                V013EquivalentCapacityEvidence(
                    scope: scope,
                    source: .officialAccountAlignedDelta,
                    lowerWeekTokens: Double(tokenDelta) * 100 / bounds.maximum,
                    upperWeekTokens: bounds.minimum > 0
                        ? Double(tokenDelta) * 100 / bounds.minimum : nil,
                    observedTokenDelta: tokenDelta,
                    displayedPercentDelta: displayedDelta,
                    sampledFrom: pair.0.observedAt,
                    sampledThrough: pair.1.observedAt,
                    resetsAt: pair.1.resetsAt,
                    sampleCount: values.count + 1
                )
            )
        }
        return values.last
    }

    private static func legacyPostCompletionNotice(
        records: [V013UsageLedgerRecord],
        accountScope: String,
        windowStart: Date,
        observedThrough: Date
    ) -> String? {
        let count = records.lazy.filter {
            isOfficial($0)
                && $0.legacyPostCompletionAccountScopeSHA256 == accountScope
                && $0.completedAt >= windowStart
                && $0.completedAt <= observedThrough
        }.count
        guard count > 0 else { return nil }
        return "历史有 \(count) 条仅完成后账号观察的调用，账号归属无法回溯确认，未纳入估算；后续仅在调用前后均有同账号观察时参与估算"
    }

    private static func cpaQuotaEvaluation(
        records: [V013UsageLedgerRecord],
        turns: [V012CompletedTurnUsage],
        observations: [V013QuotaLedgerObservation],
        accountScope: String?,
        windowStart: Date,
        resetsAt: Date,
        observedThrough: Date,
        historyCoverageComplete: Bool,
        sourceReadsStable: Bool,
        planType: String?,
        pricing: V013OfficialPricingSnapshot,
        apiPricingPolicy: V013APIPricingPolicy
    ) -> V013CPAQuotaEvaluation {
        guard historyCoverageComplete else {
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: nil,
                reason: "本周本机历史未完整覆盖，调用级区间样本暂不可用",
                observationCount: 0,
                percentageTransitionCount: 0,
                usableIntervalCount: 0
            )
        }
        guard sourceReadsStable else {
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: nil,
                reason: "本周来源正在写入，调用级区间样本暂不可用",
                observationCount: 0,
                percentageTransitionCount: 0,
                usableIntervalCount: 0
            )
        }
        guard let accountScope else {
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: nil,
                reason: "官方账号身份范围不可用，调用级配额样本不可绑定",
                observationCount: 0,
                percentageTransitionCount: 0,
                usableIntervalCount: 0
            )
        }
        let legacyNotice = legacyPostCompletionNotice(
            records: records,
            accountScope: accountScope,
            windowStart: windowStart,
            observedThrough: observedThrough
        )

        // 每个 turn 按稳定 ID 读取完成时身份。旧未绑定记录保持原样，
        // 但不再阻断整周；只有相邻官方百分比观察之间的调用全部绑定到
        // 当前可靠账号，且调用/百分比/完成时间边界对齐，该区间才参与估算。
        let recordsByID = Dictionary(
            records.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordinal = 0
        var foreignWeeklyCallCount = 0
        var calls: [V013CPAIntervalCall] = []
        for turn in turns {
            guard isOfficial(turn.providerID),
                  turn.completedAt >= windowStart,
                  turn.completedAt <= observedThrough,
                  !isCodexSpark(turn.model) else { continue }
            let binding = callBinding(
                record: recordsByID[turn.id],
                turn: turn,
                accountScope: accountScope,
                windowStart: windowStart,
                observedThrough: observedThrough
            )
            for call in turn.calls {
                defer { ordinal += 1 }
                guard call.observedAt >= windowStart,
                      call.observedAt <= observedThrough else { continue }
                if call.rateLimit.map({
                    isForeignWeeklyCycle($0, resetsAt: resetsAt)
                }) == true {
                    foreignWeeklyCallCount += 1
                    continue
                }
                let weeklyBoundaryAligned = call.rateLimit.map {
                    !$0.isWeekly || (
                        abs($0.observedAt.timeIntervalSince(call.observedAt))
                            <= 1
                            && abs($0.resetsAt.timeIntervalSince(resetsAt))
                                <= 60
                            && $0.observedAt >= windowStart
                            && $0.observedAt <= observedThrough
                    )
                } ?? true
                let milestone = call.rateLimit.flatMap {
                    milestoneRateLimit(
                        $0,
                        windowStart: windowStart,
                        resetsAt: resetsAt,
                        observedThrough: observedThrough
                    )
                }
                let cost = V012UsageCostCalculator.calculate(
                    calls: [call],
                    model: turn.pricingModel,
                    providerID: turn.providerID,
                    planType: planType,
                    serviceTier: turn.pricingServiceTier,
                    relayPricing: nil,
                    officialPricing: pricing,
                    requestBoundariesKnown: turn.containsOnlyTurnTotals != true,
                    apiPricingPolicy: apiPricingPolicy
                )
                calls.append(
                    V013CPAIntervalCall(
                        ordinal: ordinal,
                        observedAt: call.observedAt,
                        tokens: call.inputTokens + call.outputTokens,
                        credits: cost.credits,
                        apiEquivalentUSD: cost.apiEquivalentUSD,
                        milestonePercent: milestone?.usedPercent,
                        binding: binding,
                        weeklyBoundaryAligned: weeklyBoundaryAligned
                    )
                )
            }
        }
        // Exec does not emit quota headers. Reuse actual account observations
        // as zero-usage boundaries; never invent headers on the persisted calls.
        // A ledger total without its source calls is a coverage gap. Start a new
        // sample after the latest gap; old gaps must not freeze later evidence.
        let presentTurnIDs = Set(turns.map(\.id))
        let latestSourceGap = records.filter {
            !presentTurnIDs.contains($0.id) && isOfficial($0) && !isCodexSpark($0.model)
                && $0.completedAt >= windowStart && $0.completedAt <= observedThrough
        }.map(\.completedAt).max()
        let boundaries = observations.filter { observation in
            observation.accountScopeSHA256 == accountScope && observation.windowMinutes == 10_080
                && abs(observation.resetsAt.timeIntervalSince(resetsAt)) <= 60
                && observation.observedAt >= windowStart && observation.observedAt <= observedThrough
                && observation.historyCoverageComplete && observation.sourceReadsStable
                && latestSourceGap.map { observation.observedAt >= $0 } != false
        }
        // Prefer the freshest complete account observations. Counting headers
        // alone would let old, flat percentages hide later valid intervals.
        let latestCallBoundary = calls.filter {
            $0.binding == .matchingAccount && $0.milestonePercent != nil
        }.map(\.observedAt).max()
        let useAccountBoundaries = (boundaries.count >= 2
            || (boundaries.count == 1 && latestCallBoundary == nil))
            && latestCallBoundary.map { latest in
                boundaries.contains { $0.observedAt >= latest }
            } != false
        if useAccountBoundaries {
            calls = calls.map {
                V013CPAIntervalCall(ordinal: $0.ordinal, observedAt: $0.observedAt,
                        tokens: $0.tokens, credits: $0.credits,
                        apiEquivalentUSD: $0.apiEquivalentUSD, milestonePercent: nil,
                        binding: $0.binding, weeklyBoundaryAligned: $0.weeklyBoundaryAligned)
            }
            let present = Set(turns.map(\.id))
            for record in records where !present.contains(record.id)
                && isOfficial(record) && !isCodexSpark(record.model)
                && record.completedAt >= windowStart && record.completedAt <= observedThrough {
                calls.append(V013CPAIntervalCall(ordinal: ordinal, observedAt: record.completedAt,
                    tokens: record.modelProcessedTokens, credits: nil, apiEquivalentUSD: nil,
                    milestonePercent: nil, binding: .unbound, weeklyBoundaryAligned: true))
                ordinal += 1
            }
            for boundary in boundaries {
                calls.append(V013CPAIntervalCall(ordinal: ordinal, observedAt: boundary.observedAt,
                    tokens: 0, credits: 0, apiEquivalentUSD: 0,
                    milestonePercent: Double(boundary.usedPercent),
                    binding: .matchingAccount, weeklyBoundaryAligned: true))
                ordinal += 1
            }
        }
        return V013CPAIntervalEngine.evaluate(
            calls: calls, resetsAt: resetsAt,
            foreignWeeklyCallCount: foreignWeeklyCallCount,
            legacyNotice: legacyNotice,
            crossingTurnBoundaries: useAccountBoundaries ? turns.filter {
                $0.containsOnlyTurnTotals == true && isOfficial($0.providerID)
            }.map { DateInterval(start: $0.startedAt, end: $0.completedAt) } : []
        )
    }

    private static func callBinding(
        record: V013UsageLedgerRecord?,
        turn: V012CompletedTurnUsage,
        accountScope: String,
        windowStart: Date,
        observedThrough: Date
    ) -> V013CPAIntervalBinding {
        guard let record,
              isOfficial(record.providerID),
              !isCodexSpark(record.model),
              record.identityBoundAtCompletion,
              let recordScope = record.accountScopeSHA256 else {
            return .unbound
        }
        guard abs(
            record.completedAt.timeIntervalSince(turn.completedAt)
        ) <= 1,
        record.completedAt >= windowStart,
        record.completedAt <= observedThrough else {
            return .cutoffMismatch
        }
        return recordScope == accountScope
            ? .matchingAccount : .otherAccount
    }

    /// 有效周 rate_limits 才算里程碑：weekly、reset 与当前周窗口匹配、
    /// 观察时间落在窗口与快照截止之间、百分比在 0...100。
    private static func milestoneRateLimit(
        _ rateLimit: V012RateLimitObservation,
        windowStart: Date,
        resetsAt: Date,
        observedThrough: Date
    ) -> V012RateLimitObservation? {
        guard rateLimit.isWeekly,
              abs(rateLimit.resetsAt.timeIntervalSince(resetsAt)) <= 60,
              rateLimit.observedAt >= windowStart,
              rateLimit.observedAt <= observedThrough,
              rateLimit.usedPercent >= 0,
              rateLimit.usedPercent <= 100 else { return nil }
        return rateLimit
    }

    private static func isForeignWeeklyCycle(
        _ rateLimit: V012RateLimitObservation,
        resetsAt: Date
    ) -> Bool {
        rateLimit.isWeekly
            && abs(rateLimit.resetsAt.timeIntervalSince(resetsAt)) > 60
    }

    private static func isCodexSpark(_ model: String) -> Bool {
        model.lowercased().contains("codex-spark")
    }

    private static func historicalEquivalentCapacity(
        ledger: V013UsageLedgerState,
        snapshot: V011OfficialUsageSnapshot,
        currentResetsAt: Date
    ) -> V013EquivalentCapacityEvidence? {
        let historical = ledger.quotaObservations.filter {
            $0.accountScopeSHA256 == snapshot.accountScopeSHA256
                && $0.windowMinutes == 10_080
                && $0.resetsAt < currentResetsAt.addingTimeInterval(-60)
        }
        let groups = Dictionary(grouping: historical) {
            Int($0.resetsAt.timeIntervalSince1970 / 60)
        }
        return groups.values.sorted {
            ($0.first?.resetsAt ?? .distantPast)
                > ($1.first?.resetsAt ?? .distantPast)
        }.compactMap {
            equivalentCapacity(
                observations: $0,
                scope: .historicalWindow
            )
        }.first
    }

    private static func observedUsage(
        records: [V013UsageLedgerRecord],
        accountScope: String?,
        from: Date,
        through: Date,
        planType: String?,
        pricing: V013OfficialPricingSnapshot
    ) -> V013ObservedWindowUsage? {
        guard let accountScope else { return nil }
        let confirmed = records.filter {
            isOfficial($0)
                && $0.accountScopeSHA256 == accountScope
                && $0.identityBoundAtCompletion
                && $0.completedAt >= from
                && $0.completedAt <= through
        }
        return V013PricingExplanation.observedUsage(
            records: confirmed, through: through, planType: planType, pricing: pricing)
    }

    static func percentageDeltaBounds(
        from: Int,
        through: Int
    ) -> (minimum: Double, maximum: Double) {
        percentageDeltaBounds(
            from: Double(from),
            through: Double(through)
        )
    }

    static func percentageDeltaBounds(
        from: Double,
        through: Double
    ) -> (minimum: Double, maximum: Double) {
        let firstLower = max(0, from - 0.5)
        let firstUpper = min(100, from + 0.5)
        let lastLower = max(0, through - 0.5)
        let lastUpper = min(100, through + 0.5)
        return (
            max(0, lastLower - firstUpper),
            max(0, lastUpper - firstLower)
        )
    }

    private static func isOfficial(
        _ record: V013UsageLedgerRecord
    ) -> Bool {
        isOfficial(record.providerID)
    }

    private static func isOfficial(_ providerID: String) -> Bool {
        providerID.caseInsensitiveCompare("openai")
            == .orderedSame
    }
}
