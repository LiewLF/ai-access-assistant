import Foundation

// Shared CPA interval calculation. Both native ledger and CPA request capture
// supply evidence here; pricing, milestones and quantiles remain one implementation.
enum V013CPAIntervalBinding: Equatable {
    case matchingAccount
    case unbound
    case otherAccount
    case cutoffMismatch
}

struct V013CPAIntervalCall {
    let ordinal: Int
    let observedAt: Date
    let tokens: Int64
    let credits: Double?
    let apiEquivalentUSD: Double?
    let milestonePercent: Double?
    let binding: V013CPAIntervalBinding
    let weeklyBoundaryAligned: Bool
}

enum V013CPAIntervalEngine {
    private struct CPAPoint {
        let callIndex: Int
        let observedAt: Date
        let usedPercent: Double
    }

    private struct CPALowerBoundCandidate {
        let lowerFullWindowTokens: Double
        let observedTokens: Int64
        let percentDelta: Int
        let sampledFrom: Date
        let sampledThrough: Date
    }

    static func evaluate(
        calls: [V013CPAIntervalCall],
        resetsAt: Date,
        foreignWeeklyCallCount: Int = 0,
        legacyNotice: String? = nil,
        crossingTurnBoundaries: [DateInterval] = []
    ) -> V013CPAQuotaEvaluation {
        var calls = calls
        func includingLegacyNotice(_ reason: String) -> String {
            guard let legacyNotice else { return reason }
            return "\(reason)；\(legacyNotice)"
        }
        calls.sort {
            if $0.observedAt != $1.observedAt {
                return $0.observedAt < $1.observedAt
            }
            return $0.ordinal < $1.ordinal
        }

        let observedMilestones = calls.enumerated().compactMap { index, call in
            call.milestonePercent.map {
                CPAPoint(
                    callIndex: index,
                    observedAt: call.observedAt,
                    usedPercent: $0
                )
            }
        }
        let milestones = firstCrossingMilestones(in: calls)
        let milestoneCount = observedMilestones.count
        guard milestoneCount > 0 else {
            let reason = foreignWeeklyCallCount > 0
                ? "只检测到其他重置周期的周百分比观察，已隔离且不参与本周估算"
                : "正在积累可信样本：还没有同周期官方周百分比观察"
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: nil,
                reason: includingLegacyNotice(reason),
                observationCount: 0,
                percentageTransitionCount: 0,
                usableIntervalCount: 0
            )
        }
        let transitionCount = max(0, milestones.count - 1)
        guard milestones.count >= 2 else {
            let reason = milestoneCount >= 2
                ? "正在积累可信样本：相邻官方周百分比尚无递增变化"
                : "正在积累可信样本：至少需要两个相邻的同周期官方周百分比观察"
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: nil,
                reason: includingLegacyNotice(reason),
                observationCount: milestoneCount,
                percentageTransitionCount: transitionCount,
                usableIntervalCount: 0
            )
        }

        var tokenEstimates: [Double] = []
        var creditEstimates: [Double] = []
        var apiEstimates: [Double] = []
        var lowerBoundCandidates: [CPALowerBoundCandidate] = []
        var sampledTokenDeltas: [Int64] = []
        var sampledCreditDeltas: [Double?] = []
        var sampledAPIDeltas: [Double?] = []
        var sampledFrom: Date?
        var sampledThrough: Date?
        var usablePercentSpan = 0.0
        var sawUnbound = false
        var sawOtherAccount = false
        var sawCutoffMismatch = false
        var sawNoIncrease = false
        var sawExternalIncrease = false
        var anchor = milestones[0]
        for point in milestones.dropFirst() {
            let percentDelta = point.usedPercent - anchor.usedPercent
            guard percentDelta > 0 else {
                sawNoIncrease = true
                continue
            }
            guard isOfficialIntegerPercent(anchor.usedPercent),
                  isOfficialIntegerPercent(point.usedPercent) else {
                return V013CPAQuotaEvaluation(
                    estimate: nil,
                    partialCapacity: nil,
                    reason: includingLegacyNotice(
                        "官方调用级百分比精度无法按整数边界核对，调用级区间暂不可用"
                    ),
                    observationCount: milestoneCount,
                    percentageTransitionCount: transitionCount,
                    usableIntervalCount: 0
                )
            }
            let intervalCalls = Array(
                calls[anchor.callIndex...point.callIndex]
            )
            if crossingTurnBoundaries.contains(where: {
                $0.start < anchor.observedAt && $0.end > anchor.observedAt
                    && $0.end <= point.observedAt
            }) {
                sawCutoffMismatch = true
                anchor = point
                continue
            }
            if intervalCalls.contains(where: {
                !$0.weeklyBoundaryAligned
                    || $0.binding == .cutoffMismatch
            }) {
                sawCutoffMismatch = true
                anchor = point
                continue
            }
            if intervalCalls.contains(where: {
                $0.binding == .otherAccount
            }) {
                sawOtherAccount = true
                anchor = point
                continue
            }
            if intervalCalls.contains(where: {
                $0.binding == .unbound
            }) {
                sawUnbound = true
                let measuredCalls = intervalCalls.dropFirst()
                let identityBoundCalls = measuredCalls.filter {
                    $0.binding == .matchingAccount
                }
                let identityBoundTokens = identityBoundCalls.reduce(Int64(0)) {
                    $0 + $1.tokens
                }
                if intervalCalls.first?.binding == .matchingAccount,
                   intervalCalls.last?.binding == .matchingAccount,
                   identityBoundTokens > 0 {
                    lowerBoundCandidates.append(
                        CPALowerBoundCandidate(
                            lowerFullWindowTokens:
                                Double(identityBoundTokens) * 100
                                / V013UsageEvidenceBuilder.percentageDeltaBounds(from: anchor.usedPercent,
                                    through: point.usedPercent).maximum,
                            observedTokens: identityBoundTokens,
                            percentDelta: Int(percentDelta),
                            sampledFrom: anchor.observedAt,
                            sampledThrough: point.observedAt
                        )
                    )
                }
                anchor = point
                continue
            }
            let measuredCalls = intervalCalls.dropFirst()
            let tokenDelta = measuredCalls.reduce(Int64(0)) {
                $0 + $1.tokens
            }
            let creditDelta = completeSum(
                measuredCalls.map(\.credits)
            ).flatMap { $0 > 0 ? $0 : nil }
            let apiDelta = completeSum(
                measuredCalls.map(\.apiEquivalentUSD)
            ).flatMap { $0 > 0 ? $0 : nil }
            let hasMeasuredIncrease = tokenDelta > 0
                || creditDelta != nil
                || apiDelta != nil
            guard hasMeasuredIncrease else {
                sawExternalIncrease = true
                anchor = point
                continue
            }
            if tokenDelta > 0 {
                tokenEstimates.append(
                    Double(tokenDelta) * 100 / percentDelta
                )
                sampledTokenDeltas.append(tokenDelta)
                sampledCreditDeltas.append(creditDelta)
                sampledAPIDeltas.append(apiDelta)
                sampledFrom = sampledFrom ?? anchor.observedAt
                sampledThrough = point.observedAt
                usablePercentSpan += percentDelta
            }
            if let creditDelta {
                creditEstimates.append(
                    creditDelta * 100 / percentDelta
                )
            }
            if let apiDelta {
                apiEstimates.append(
                    apiDelta * 100 / percentDelta
                )
            }
            anchor = point
        }
        guard !tokenEstimates.isEmpty,
              let firstSampledAt = sampledFrom,
              let lastSampledAt = sampledThrough else {
            let partialCapacity = lowerBoundCandidates.min {
                $0.lowerFullWindowTokens < $1.lowerFullWindowTokens
            }.map { candidate in
                V013EquivalentCapacityEvidence(
                    scope: .currentWindow,
                    source: .localIdentityBoundLowerBound,
                    lowerWeekTokens: candidate.lowerFullWindowTokens,
                    upperWeekTokens: nil,
                    observedTokenDelta: candidate.observedTokens,
                    displayedPercentDelta: candidate.percentDelta,
                    sampledFrom: candidate.sampledFrom,
                    sampledThrough: candidate.sampledThrough,
                    resetsAt: resetsAt,
                    sampleCount: lowerBoundCandidates.count
                )
            }
            let reason: String
            var blockers: [String] = []
            if sawCutoffMismatch {
                blockers.append("可信样本区间时间截止点不一致")
            }
            if sawOtherAccount {
                blockers.append("可信样本区间账号不一致")
            }
            if sawUnbound {
                blockers.append("候选区间内存在未绑定官方账号的调用")
            }
            if sawExternalIncrease {
                blockers.append("检测到官方百分比上升但本机无对应用量")
            }
            if partialCapacity != nil {
                reason = "候选区间内存在未绑定官方账号的调用；仅使用完成时身份有前后同账号观察的本机调用给出可信下限，上界未知"
            } else if !blockers.isEmpty {
                let flatTail = observedMilestones.suffix(2)
                let unchanged = flatTail.count == 2
                    && flatTail.first?.usedPercent == flatTail.last?.usedPercent
                reason = blockers.joined(separator: "；")
                    + (unchanged ? "；最近官方周百分比尚无递增变化，新的完整区间可独立参与估算" : "")
            } else if sawNoIncrease {
                reason = "正在积累可信样本：相邻官方周百分比尚无递增变化"
            } else {
                reason = "正在积累可信样本：相邻观察之间没有可计量 Token 增量"
            }
            return V013CPAQuotaEvaluation(
                estimate: nil,
                partialCapacity: partialCapacity,
                reason: includingLegacyNotice(reason),
                observationCount: milestoneCount,
                percentageTransitionCount: transitionCount,
                usableIntervalCount: 0
            )
        }
        let sampleCount = [
            tokenEstimates.count,
            creditEstimates.count,
            apiEstimates.count,
        ].max() ?? 0
        let confidence: V013WeeklyUsageEstimate.Confidence
        if sampleCount >= 5, usablePercentSpan >= 5 {
            confidence = .high
        } else if sampleCount >= 2, usablePercentSpan >= 2 {
            confidence = .medium
        } else {
            confidence = .low
        }
        return V013CPAQuotaEvaluation(
            estimate: V013CPAQuotaEstimate(
                pointFullWindowTokens: quantile(
                    tokenEstimates,
                    0.5
                ),
                lowerFullWindowTokens: quantile(
                    tokenEstimates,
                    0.25
                ),
                upperFullWindowTokens: quantile(
                    tokenEstimates,
                    0.75
                ),
                pointFullWindowCredits: optionalQuantile(
                    creditEstimates,
                    0.5
                ),
                lowerFullWindowCredits: optionalQuantile(
                    creditEstimates,
                    0.25
                ),
                upperFullWindowCredits: optionalQuantile(
                    creditEstimates,
                    0.75
                ),
                pointFullWindowAPIEquivalentUSD: optionalQuantile(
                    apiEstimates,
                    0.5
                ),
                lowerFullWindowAPIEquivalentUSD: optionalQuantile(
                    apiEstimates,
                    0.25
                ),
                upperFullWindowAPIEquivalentUSD: optionalQuantile(
                    apiEstimates,
                    0.75
                ),
                observedTokens: sampledTokenDeltas.reduce(0, +),
                observedCredits: completeSum(sampledCreditDeltas),
                observedAPIEquivalentUSD:
                    completeSum(sampledAPIDeltas),
                percentSpan: usablePercentSpan,
                lastUsedPercent: milestones.last?.usedPercent ?? 0,
                sampledFrom: firstSampledAt,
                sampledThrough: lastSampledAt,
                confidence: confidence,
                apiIntervalSampleCount: apiEstimates.count,
                creditsIntervalSampleCount: creditEstimates.count
            ),
            partialCapacity: nil,
            reason: "仅使用同账号、同重置周期、首次递增周百分比里程碑且截止点对齐的调用；中位数为点估计；P25–P75 仅描述多个区间的样本分布，不是置信区间"
                + (foreignWeeklyCallCount > 0
                    ? "；已隔离 \(foreignWeeklyCallCount) 条其他重置周期调用"
                    : ""),
            observationCount: milestoneCount,
            percentageTransitionCount: transitionCount,
            usableIntervalCount: tokenEstimates.count
        )
    }

    /// Behavioral adaptation of CPA Quota Estimator's MIT-licensed
    /// monotonic milestone rule: repeated samples keep contributing usage,
    /// while only the first crossing of each new high creates a boundary.
    /// This Swift variant additionally keeps account/reset guards and ±0.5
    /// bounded percentage math.
    private static func firstCrossingMilestones(
        in calls: [V013CPAIntervalCall]
    ) -> [CPAPoint] {
        var highestPercent: Double?
        var result: [CPAPoint] = []
        for (index, call) in calls.enumerated() {
            guard let usedPercent = call.milestonePercent,
                  highestPercent.map({ usedPercent > $0 }) != false else {
                continue
            }
            result.append(
                CPAPoint(
                    callIndex: index,
                    observedAt: call.observedAt,
                    usedPercent: usedPercent
                )
            )
            highestPercent = usedPercent
        }
        return result
    }

    private static func optionalQuantile(
        _ values: [Double],
        _ q: Double
    ) -> Double? {
        values.isEmpty ? nil : quantile(values, q)
    }

    private static func quantile(
        _ values: [Double],
        _ q: Double
    ) -> Double {
        let ordered = values.sorted()
        guard ordered.count > 1 else { return ordered.first ?? 0 }
        let position = q * Double(ordered.count - 1)
        let lowerIndex = Int(floor(position))
        let upperIndex = Int(ceil(position))
        guard lowerIndex != upperIndex else { return ordered[lowerIndex] }
        return ordered[lowerIndex]
            + (ordered[upperIndex] - ordered[lowerIndex])
                * (position - Double(lowerIndex))
    }

    private static func isOfficialIntegerPercent(_ value: Double) -> Bool {
        value.isFinite && abs(value - value.rounded()) < 0.000_001
    }

    private static func completeSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return values.compactMap { $0 }.reduce(0, +)
    }

}
