import Foundation

/// Selects an independent capture or native estimate without splicing gaps.
enum V013CPAEvidenceSelection {
    static func evaluate(
        snapshots: [V013CPARawUsageSnapshot],
        officialSnapshot: V011OfficialUsageSnapshot,
        window: V011OfficialUsageWindow,
        pricing: V013OfficialPricingSnapshot,
        now: Date? = nil,
        nativeEvaluation: V013CPAQuotaEvaluation? = nil
    ) -> V013CPAQuotaEvaluation? {
        var candidates = snapshots.filter {
            $0.expectedOfficialAccountScopeSHA256 == officialSnapshot.accountScopeSHA256
        }.map {
            V013CPAEvidenceAdapter.evaluate(raw: $0,
                officialSnapshot: officialSnapshot, window: window, pricing: pricing, now: now)
        }
        if let nativeEvaluation { candidates.append(nativeEvaluation) }
        // Complete monetary evidence takes precedence over Token-only samples.
        // Within that class, retain the most recently completed usable interval.
        let complete = candidates.filter {
            $0.estimate?.pointFullWindowAPIEquivalentUSD != nil
                && $0.estimate?.pointFullWindowCredits != nil
        }
        let usable = complete.isEmpty ? candidates.filter { $0.estimate != nil } : complete
        if let selected = usable.max(by: {
            ($0.estimate?.sampledThrough ?? .distantPast)
                < ($1.estimate?.sampledThrough ?? .distantPast)
        }) { return selected }
        return candidates.max { $0.observationCount < $1.observationCount }
    }
}
