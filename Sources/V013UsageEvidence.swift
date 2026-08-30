import Foundation

struct V012PendingUsageRefresh {
    let rows: [V011SessionRow]
    let historyHasMore: Bool
    let officialSnapshot: V011OfficialUsageSnapshot?
    let profiles: [CodexRelayProfile]
}

struct V013ObservedWindowUsage: Equatable {
    let requestCount: Int
    let tokens: Int64
    let apiEquivalentUSD: Double?
    let observedFrom: Date
    let observedThrough: Date
}

struct V013SupplementalUsageEvidence: Equatable {
    let observed: V013ObservedWindowUsage?
    let officialActivity: V013OfficialActivityEvidence?
    let currentEquivalentCapacity: V013EquivalentCapacityEvidence?
    let localStructureReference: V013LocalStructureCapacityReference?
    let historicalEquivalentCapacity: V013EquivalentCapacityEvidence?
    let percentageTransitionCount: Int
    let usableIntervalCount: Int

    static let empty = Self(
        observed: nil,
        officialActivity: nil,
        currentEquivalentCapacity: nil,
        localStructureReference: nil,
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

struct V013LocalStructureCapacityReference: Equatable {
    let lowerWeekTokens: Double
    let lowerWeekAPIEquivalentUSD: Double?
    let observedTokens: Int64
    let requestCount: Int
    let identityBoundTokens: Int64
    let displayedPercentFrom: Int
    let displayedPercentThrough: Int
    let sampledFrom: Date
    let sampledThrough: Date
    let resetsAt: Date
    let excludesOtherDevices: Bool
}

struct V013EquivalentCapacityEvidence: Equatable {
    enum Scope: String { case currentWindow, historicalWindow }
    enum Source: String {
        case officialAccountAlignedDelta
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
        planType: String?,
        pricing: V013OfficialPricingSnapshot
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
        let currentEquivalent = equivalentCapacity(
            observations: observations,
            scope: .currentWindow
        )
        let localReference = localStructureReference(
            ledger: ledger,
            snapshot: snapshot,
            observations: observations,
            planType: planType,
            pricing: pricing
        )
        let historicalEquivalent = historicalEquivalentCapacity(
            ledger: ledger,
            snapshot: snapshot,
            currentResetsAt: resetsAt
        )
        let usableIntervals = currentEquivalent?.sampleCount
            ?? accountAlignedLocalIntervalCount(
                ledger: ledger,
                snapshot: snapshot,
                observations: observations
            )
        return V013SupplementalUsageEvidence(
            observed: observed,
            officialActivity: officialActivity,
            currentEquivalentCapacity: currentEquivalent,
            localStructureReference: localReference,
            historicalEquivalentCapacity: historicalEquivalent,
            percentageTransitionCount: transitionCount(observations),
            usableIntervalCount: usableIntervals
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
        guard latest != nil || !local.isEmpty else { return nil }
        return V013OfficialActivityEvidence(
            latestDailyBucket: latest?.startDate,
            latestDailyBucketTokens: latest?.tokens,
            dailyBucketBoundaryKnown: false,
            localWindowTokens: local.reduce(0) { $0 + $1.billableTokens },
            localWindowIdentityBoundTokens: local.filter {
                $0.accountScopeSHA256 == snapshot.accountScopeSHA256
                    && $0.identityBoundAtCompletion
            }.reduce(0) { $0 + $1.billableTokens },
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

    private static func localStructureReference(
        ledger: V013UsageLedgerState,
        snapshot: V011OfficialUsageSnapshot,
        observations: [V013QuotaLedgerObservation],
        planType: String?,
        pricing: V013OfficialPricingSnapshot
    ) -> V013LocalStructureCapacityReference? {
        let milestones = monotonicMilestones(observations)
        guard let first = milestones.first,
              let last = milestones.last,
              last.usedPercent > first.usedPercent else { return nil }
        let records = ledger.records.filter {
            isOfficial($0)
                && $0.completedAt > first.observedAt
                && $0.completedAt <= last.observedAt
        }
        let tokens = records.reduce(Int64(0)) { $0 + $1.billableTokens }
        let bounds = percentageDeltaBounds(
            from: first.usedPercent,
            through: last.usedPercent
        )
        guard tokens > 0, bounds.maximum > 0 else { return nil }
        let api = completeSum(records.map {
            $0.repriced(
                officialPricing: pricing,
                planType: planType
            ).apiEquivalentUSD
        })
        return V013LocalStructureCapacityReference(
            lowerWeekTokens: Double(tokens) * 100 / bounds.maximum,
            lowerWeekAPIEquivalentUSD: api.map {
                $0 * 100 / bounds.maximum
            },
            observedTokens: tokens,
            requestCount: records.count,
            identityBoundTokens: records.filter {
                $0.accountScopeSHA256 == snapshot.accountScopeSHA256
                    && $0.identityBoundAtCompletion
            }.reduce(0) { $0 + $1.billableTokens },
            displayedPercentFrom: first.usedPercent,
            displayedPercentThrough: last.usedPercent,
            sampledFrom: first.observedAt,
            sampledThrough: last.observedAt,
            resetsAt: last.resetsAt,
            excludesOtherDevices: true
        )
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
        accountScope: String,
        from: Date,
        through: Date,
        planType: String?,
        pricing: V013OfficialPricingSnapshot
    ) -> V013ObservedWindowUsage? {
        let confirmed = records.filter {
            isOfficial($0)
                && $0.accountScopeSHA256 == accountScope
                && $0.identityBoundAtCompletion
                && $0.completedAt >= from
                && $0.completedAt <= through
        }
        let tokens = confirmed.reduce(Int64(0)) {
            $0 + $1.billableTokens
        }
        guard tokens > 0,
              let first = confirmed.map(\.completedAt).min() else {
            return nil
        }
        return V013ObservedWindowUsage(
            requestCount: confirmed.count,
            tokens: tokens,
            apiEquivalentUSD: completeSum(confirmed.map {
                $0.repriced(
                    officialPricing: pricing,
                    planType: planType
                ).apiEquivalentUSD
            }),
            observedFrom: first,
            observedThrough: through
        )
    }

    private static func monotonicMilestones(
        _ values: [V013QuotaLedgerObservation]
    ) -> [V013QuotaLedgerObservation] {
        let ordered = values.sorted { $0.observedAt < $1.observedAt }
        guard let first = ordered.first else { return [] }
        var result = [first]
        var maximum = first.usedPercent
        for value in ordered.dropFirst() where value.usedPercent > maximum {
            result.append(value)
            maximum = value.usedPercent
        }
        return result
    }

    private static func accountAlignedLocalIntervalCount(
        ledger: V013UsageLedgerState,
        snapshot: V011OfficialUsageSnapshot,
        observations: [V013QuotaLedgerObservation]
    ) -> Int {
        zip(observations, observations.dropFirst()).reduce(0) {
            count, pair in
            guard pair.1.usedPercent > pair.0.usedPercent,
                  pair.0.historyCoverageComplete,
                  pair.1.historyCoverageComplete,
                  pair.0.sourceReadsStable,
                  pair.1.sourceReadsStable else { return count }
            let records = ledger.records.filter {
                isOfficial($0)
                    && $0.completedAt > pair.0.observedAt
                    && $0.completedAt <= pair.1.observedAt
            }
            guard !records.isEmpty,
                  records.allSatisfy({
                      $0.accountScopeSHA256
                          == snapshot.accountScopeSHA256
                          && $0.identityBoundAtCompletion
                  }) else { return count }
            return count + 1
        }
    }

    private static func percentageDeltaBounds(
        from: Int,
        through: Int
    ) -> (minimum: Double, maximum: Double) {
        let firstLower = max(0, Double(from) - 0.5)
        let firstUpper = min(100, Double(from) + 0.5)
        let lastLower = max(0, Double(through) - 0.5)
        let lastUpper = min(100, Double(through) + 0.5)
        return (
            max(0, lastLower - firstUpper),
            max(0, lastUpper - firstLower)
        )
    }

    private static func transitionCount(
        _ values: [V013QuotaLedgerObservation]
    ) -> Int {
        max(0, monotonicMilestones(values).count - 1)
    }

    private static func completeSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

    private static func isOfficial(
        _ record: V013UsageLedgerRecord
    ) -> Bool {
        record.providerID.caseInsensitiveCompare("openai")
            == .orderedSame
    }
}
