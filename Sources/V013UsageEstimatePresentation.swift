import Foundation

/// Presentation only: preserves the estimator's values and evidence requirements.
struct V013UsageEstimatePresentation {
    enum Quantity { case tokens, apiUSD, credits }

    let estimate: V013WeeklyUsageEstimate

    var methodText: String {
        estimate.usableIntervalSampleCount < 2
            ? "单区间初步参考" : "中位数 · P25–P75 样本分布"
    }

    var reliabilityText: String {
        "Token 估算 · \(estimate.usableIntervalSampleCount) 个可信区间 · 置信度\(estimate.confidence.rawValue)"
            + (estimate.usableIntervalSampleCount < 2 ? " · 暂不足以形成统计范围" : "")
    }

    func point(_ value: Double?, as quantity: Quantity) -> String {
        guard let value, value.isFinite, value >= 0 else { return "暂不可估算" }
        return "约 " + formatted(value, as: quantity)
    }

    func rangeNote(lower: Double?, upper: Double?, as quantity: Quantity) -> String {
        let count = sampleCount(for: quantity)
        guard count > 0 else { return "尚无可用区间" }
        guard count >= 2 else {
            return "仅 1 个可信区间，置信度低；统计范围尚不足"
        }
        guard let lower, let upper, lower.isFinite, upper.isFinite,
              lower >= 0, upper >= lower else { return "统计范围暂不可估算" }
        let low = formatted(lower, as: quantity)
        let high = formatted(upper, as: quantity)
        guard low != high else { return "样本分位数接近，误差仍未确定" }
        return "样本 P25–P75：\(low)–\(high)；不是置信区间"
    }

    func pricingCoverage(as quantity: Quantity) -> String {
        let count = sampleCount(for: quantity)
        let total = estimate.usableIntervalSampleCount
        return "\(count)/\(total) 个可信区间可计价；"
            + (count < total ? "仅按可计价样本外推；" : "")
    }

    private func sampleCount(for quantity: Quantity) -> Int {
        switch quantity {
        case .tokens: return estimate.usableIntervalSampleCount
        case .apiUSD: return estimate.apiIntervalSampleCount
        case .credits: return estimate.creditsIntervalSampleCount
        }
    }

    private func formatted(_ value: Double, as quantity: Quantity) -> String {
        func number(_ value: Double) -> String {
            value.formatted(.number.precision(.significantDigits(3)))
        }
        switch quantity {
        case .apiUSD: return "$" + number(value)
        case .credits: return number(value)
        case .tokens:
            if value >= 100_000_000 { return number(value / 100_000_000) + " 亿" }
            if value >= 10_000 { return number(value / 10_000) + " 万" }
            return number(value)
        }
    }
}
