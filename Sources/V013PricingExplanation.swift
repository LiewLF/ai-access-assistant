import Foundation

/// Explains missing evidence without substituting models, tiers, or token fields.
enum V013PricingExplanation {
    static func missingEvidence(
        calls: [V012UpstreamTokenUsage], model: String, serviceTier: String?,
        planType: String?, pricing: V013OfficialPricingSnapshot,
        requestBoundariesKnown: Bool
    ) -> [String] {
        var issues: [String] = []
        if !pricing.isStructurallyValid { issues.append("官方价表无效") }
        if pricing.rate(model: model, serviceTier: "standard") == nil {
            issues.append("\(model) 缺少已核实官方价格")
        }
        let tier = serviceTier?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if tier == nil || tier == "" || tier == "unknown" || tier == "auto" {
            issues.append("\(model) 服务档位未确认，不默认按标准价")
        } else if V013OfficialPricingSnapshot.normalizedTier(tier) == nil {
            issues.append("\(model) 服务档位无已核实价格")
        }
        if calls.contains(where: { $0.cacheWriteInputTokens == nil }) {
            issues.append("缺少缓存写入 Token 字段，不能补零")
        }
        if !requestBoundariesKnown,
           let rate = pricing.rate(model: model, serviceTier: serviceTier),
           calls.contains(where: { $0.inputTokens > rate.longContextThreshold }) {
            issues.append("API 长上下文计价缺少逐次请求边界")
        }
        if !pricing.supportsSubscriptionCredits(planType: planType) {
            issues.append("credits 缺少适用套餐证据")
        }
        return issues
    }

    static func observedUsage(
        records: [V013UsageLedgerRecord], through: Date, planType: String?,
        pricing: V013OfficialPricingSnapshot
    ) -> V013ObservedWindowUsage? {
        let tokens = records.reduce(Int64(0)) { $0 + $1.modelProcessedTokens }
        guard tokens > 0, let first = records.map(\.completedAt).min() else { return nil }
        let costs = records.map { $0.repriced(officialPricing: pricing, planType: planType) }
        func completeSum(_ values: [Double?]) -> Double? {
            guard values.allSatisfy({ $0 != nil }) else { return nil }
            return values.compactMap { $0 }.reduce(0, +)
        }
        let issues = zip(records, costs).compactMap { record, cost -> String? in
            guard cost.apiEquivalentUSD == nil || cost.credits == nil else { return nil }
            return "\(record.model)：\(cost.pricingEvidence)"
        }
        return V013ObservedWindowUsage(
            requestCount: records.count, tokens: tokens,
            apiEquivalentUSD: completeSum(costs.map(\.apiEquivalentUSD)),
            observedFrom: first, observedThrough: through,
            credits: completeSum(costs.map(\.credits)),
            pricingIssues: Array(Set(issues)).sorted())
    }
}
