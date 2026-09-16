import Foundation

/// Reference pricing is opt-in. It never rewrites the recorded tier or prices credits.
enum V013APIPricingPolicy {
    case recordedTier
    case standardReferenceWhenMissing

    static func tierIsMissing(_ tier: String?) -> Bool {
        let value = tier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value == nil || value == "" || value == "unknown" || value == "auto"
    }
}

struct V013LocalUsageReference: Equatable {
    let tokens: Int64
    let requestCount: Int
    let pricedRequestCount: Int
    let assumedStandardCount: Int
    let pricedAPIEquivalentUSD: Double
    let from: Date
    let through: Date
    let pricingCheckedAt: Date
    let issues: [String]

    var isFullyPriced: Bool { requestCount > 0 && pricedRequestCount == requestCount }

    static func build(
        records: [V013UsageLedgerRecord], through: Date,
        pricing: V013OfficialPricingSnapshot
    ) -> Self? {
        let from = through.addingTimeInterval(-7 * 24 * 60 * 60)
        let local = records.filter {
            $0.isStructurallyValid && $0.providerID.lowercased() == "openai"
                && $0.completedAt >= from && $0.completedAt <= through
        }
        guard !local.isEmpty else { return nil }
        let costs = local.map {
            $0.repriced(officialPricing: pricing, planType: nil,
                apiPricingPolicy: .standardReferenceWhenMissing)
        }
        let priced = zip(local, costs).filter { $0.1.apiEquivalentUSD != nil }
        return Self(
            tokens: local.reduce(0) { $0 + $1.modelProcessedTokens },
            requestCount: local.count, pricedRequestCount: priced.count,
            assumedStandardCount: priced.filter {
                V013APIPricingPolicy.tierIsMissing(
                    $0.0.completedUsage?.pricingServiceTier ?? $0.0.serviceTier)
            }.count,
            pricedAPIEquivalentUSD: priced.reduce(0) { $0 + ($1.1.apiEquivalentUSD ?? 0) },
            from: from, through: through, pricingCheckedAt: pricing.effectiveAPICheckedAt,
            issues: Array(Set(costs.filter { $0.apiEquivalentUSD == nil }
                .map(\.pricingEvidence))).sorted()
        )
    }
}

/// Uses the existing estimator twice with explicit policies; no second interval algorithm.
struct V013UsagePresentation {
    let strict: V013WeeklyUsageStatus
    let local: V013LocalUsageReference?
    let apiReference: V013WeeklyUsageEstimate?

    /// Active product path: observed usage only. Retired capacity estimates are not evaluated.
    static func observedUsage(
        ledger: V013UsageLedgerState, pricing: V013OfficialPricingSnapshot, now: Date
    ) -> Self {
        Self(strict: .notRead,
            local: .build(records: ledger.records, through: now, pricing: pricing),
            apiReference: nil)
    }

    // Retained for historical evidence replay; no production caller.
    static func evaluate(
        ledger: V013UsageLedgerState, officialSnapshot: V011OfficialUsageSnapshot?,
        planType: String?, pricing: V013OfficialPricingSnapshot, now: Date,
        turns: [V012CompletedTurnUsage], historyCoverageComplete: Bool,
        sourceReadsStable: Bool, cpaSnapshots: [V013CPARawUsageSnapshot]
    ) -> Self {
        func status(_ policy: V013APIPricingPolicy) -> V013WeeklyUsageStatus {
            V013WeeklyUsageEstimator.evaluate(
                ledger: ledger, officialSnapshot: officialSnapshot, planType: planType,
                pricing: pricing, now: now, turns: turns,
                historyCoverageComplete: historyCoverageComplete,
                sourceReadsStable: sourceReadsStable, cpaSnapshots: cpaSnapshots,
                apiPricingPolicy: policy)
        }
        let strict = status(.recordedTier)
        // No quota change is needed for the local amount. Only an existing valid
        // interval can support the optional full-window reference projection.
        let reference = strict.estimate != nil && strict.estimate?.pointWeekAPIEquivalentUSD == nil
            ? status(.standardReferenceWhenMissing).estimate : nil
        return Self(strict: strict,
            local: .build(records: ledger.records, through: now, pricing: pricing),
            apiReference: reference)
    }
}
