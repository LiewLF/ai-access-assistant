import Foundation

struct V013OfficialPricingRate: Codable, Equatable, Identifiable {
    let model: String
    let serviceTier: String
    let creditsInputPerMillion: Double
    let creditsCachedInputPerMillion: Double
    let creditsOutputPerMillion: Double
    let apiInputPerMillionUSD: Double
    let apiCachedInputPerMillionUSD: Double
    let apiCacheWritePerMillionUSD: Double
    let apiOutputPerMillionUSD: Double
    let longContextThreshold: Int64
    let longContextInputMultiplier: Double
    let longContextOutputMultiplier: Double

    var id: String { "\(model.lowercased())|\(serviceTier)" }

    var isStructurallyValid: Bool {
        V012ModelTokenRate.safeText(model, maximumBytes: 128)
            && (serviceTier == "standard" || serviceTier == "fast")
            && [
                creditsInputPerMillion,
                creditsCachedInputPerMillion,
                creditsOutputPerMillion,
                apiInputPerMillionUSD,
                apiCachedInputPerMillionUSD,
                apiCacheWritePerMillionUSD,
                apiOutputPerMillionUSD,
                longContextInputMultiplier,
                longContextOutputMultiplier,
            ].allSatisfy {
                $0.isFinite && $0 >= 0 && $0 <= 1_000_000_000
            }
            && longContextThreshold > 0
    }
}

/// Immutable, versioned official rate-card snapshot. Subscription credits and
/// API-equivalent USD share one explicit source set but remain separate values.
struct V013OfficialPricingSnapshot: Codable, Equatable, Identifiable {
    static let schemaVersion = 2

    let version: Int
    let effectiveAt: Date
    let checkedAt: Date
    let creditsCheckedAt: Date?
    let apiCheckedAt: Date?
    let speedCheckedAt: Date?
    let subscriptionSourceURL: String
    let apiSourceURL: String
    let speedSourceURL: String
    let rates: [V013OfficialPricingRate]

    var id: String {
        "official-pricing-\(Int(effectiveAt.timeIntervalSince1970))"
    }

    var effectiveCreditsCheckedAt: Date {
        creditsCheckedAt ?? checkedAt
    }

    var effectiveAPICheckedAt: Date {
        apiCheckedAt ?? checkedAt
    }

    var effectiveSpeedCheckedAt: Date {
        speedCheckedAt ?? checkedAt
    }

    init(
        version: Int,
        effectiveAt: Date,
        checkedAt: Date,
        creditsCheckedAt: Date? = nil,
        apiCheckedAt: Date? = nil,
        speedCheckedAt: Date? = nil,
        subscriptionSourceURL: String,
        apiSourceURL: String,
        speedSourceURL: String,
        rates: [V013OfficialPricingRate]
    ) {
        self.version = version
        self.effectiveAt = effectiveAt
        self.checkedAt = checkedAt
        self.creditsCheckedAt = creditsCheckedAt
        self.apiCheckedAt = apiCheckedAt
        self.speedCheckedAt = speedCheckedAt
        self.subscriptionSourceURL = subscriptionSourceURL
        self.apiSourceURL = apiSourceURL
        self.speedSourceURL = speedSourceURL
        self.rates = rates
    }

    var isStructurallyValid: Bool {
        version == Self.schemaVersion
            && effectiveAt <= checkedAt
            && [
                creditsCheckedAt,
                apiCheckedAt,
                speedCheckedAt,
            ].allSatisfy { date in
                date.map {
                    $0.timeIntervalSince1970.isFinite
                        && $0 <= checkedAt
                } != false
            }
            && [
                subscriptionSourceURL,
                apiSourceURL,
                speedSourceURL,
            ].allSatisfy {
                V012PricingManifestFetcher.safeURL($0) != nil
            }
            && !rates.isEmpty
            && rates.count <= 64
            && rates.allSatisfy(\.isStructurallyValid)
            && Set(rates.map(\.id)).count == rates.count
    }

    func hasSamePricing(as other: Self) -> Bool {
        rates.sorted { $0.id < $1.id }
            == other.rates.sorted { $0.id < $1.id }
    }

    func rate(
        model: String,
        serviceTier: String?
    ) -> V013OfficialPricingRate? {
        guard let tier = Self.normalizedTier(serviceTier) else {
            return nil
        }
        let normalizedModel = Self.normalizedModel(model)
        return rates.first {
            $0.model == normalizedModel && $0.serviceTier == tier
        }
    }

    func supportsSubscriptionCredits(planType: String?) -> Bool {
        guard let plan = planType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() else { return false }
        return [
            "plus", "pro", "business", "team", "enterprise",
            "edu", "health", "gov",
        ].contains(plan)
    }

    func replacingAPIPrices(
        _ prices: [String: (input: Double, cached: Double, output: Double)],
        checkedAt: Date,
        fastMultiplier: Double = 2
    ) -> Self? {
        guard Set(prices.keys) == Set(rates.map(\.model)),
              fastMultiplier.isFinite,
              fastMultiplier > 0 else { return nil }
        let updated = rates.compactMap { current -> V013OfficialPricingRate? in
            guard let value = prices[current.model] else { return nil }
            let multiplier = current.serviceTier == "fast"
                ? fastMultiplier : 1
            return V013OfficialPricingRate(
                model: current.model,
                serviceTier: current.serviceTier,
                creditsInputPerMillion:
                    current.creditsInputPerMillion,
                creditsCachedInputPerMillion:
                    current.creditsCachedInputPerMillion,
                creditsOutputPerMillion:
                    current.creditsOutputPerMillion,
                apiInputPerMillionUSD: value.input * multiplier,
                apiCachedInputPerMillionUSD:
                    value.cached * multiplier,
                apiCacheWritePerMillionUSD:
                    value.input * 1.25 * multiplier,
                apiOutputPerMillionUSD: value.output * multiplier,
                longContextThreshold: current.longContextThreshold,
                longContextInputMultiplier:
                    current.longContextInputMultiplier,
                longContextOutputMultiplier:
                    current.longContextOutputMultiplier
            )
        }
        guard updated.count == rates.count else { return nil }
        let pricingUnchanged = updated == rates
        let value = Self(
            version: version,
            effectiveAt: pricingUnchanged ? effectiveAt : checkedAt,
            checkedAt: checkedAt,
            creditsCheckedAt: effectiveCreditsCheckedAt,
            apiCheckedAt: checkedAt,
            speedCheckedAt: checkedAt,
            subscriptionSourceURL: subscriptionSourceURL,
            apiSourceURL: apiSourceURL,
            speedSourceURL: speedSourceURL,
            rates: updated
        )
        return value.isStructurallyValid ? value : nil
    }

    static let current: Self = {
        let checkedAt = ISO8601DateFormatter().date(
            from: "2026-09-04T22:31:03Z"
        )!
        let effectiveAt = ISO8601DateFormatter().date(
            from: "2026-09-04T22:31:03Z"
        )!
        let standard: [(String, Double, Double, Double, Double, Double, Double)] = [
            ("gpt-6-astra", 250, 25, 1250, 10, 1, 50),
            ("gpt-5.6-sol", 100, 10, 500, 4, 0.4, 20),
            ("gpt-5.6-terra", 50, 5, 300, 2, 0.2, 12),
            ("gpt-5.6-luna", 5, 0.5, 30, 0.2, 0.02, 1.2),
        ]
        var rates: [V013OfficialPricingRate] = []
        for value in standard {
            rates.append(
                rate(
                    model: value.0,
                    serviceTier: "standard",
                    creditsInput: value.1,
                    creditsCached: value.2,
                    creditsOutput: value.3,
                    apiInput: value.4,
                    apiCached: value.5,
                    apiOutput: value.6
                )
            )
            rates.append(
                rate(
                    model: value.0,
                    serviceTier: "fast",
                    creditsInput: value.1 * 2.5,
                    creditsCached: value.2 * 2.5,
                    creditsOutput: value.3 * 2.5,
                    apiInput: value.4 * 2,
                    apiCached: value.5 * 2,
                    apiOutput: value.6 * 2
                )
            )
        }
        let source = "https://learn.chatgpt.com/docs/pricing"
        let api = "https://developers.openai.com/api/docs/models/compare"
        let speed = "https://developers.openai.com/codex/speed"
        return Self(
            version: schemaVersion,
            effectiveAt: effectiveAt,
            checkedAt: checkedAt,
            creditsCheckedAt: checkedAt,
            // Astra was checked on Sep 5; unchanged models keep their older
            // API/Speed verification floor. Do not claim a full catalog refresh.
            apiCheckedAt: ISO8601DateFormatter().date(from: "2026-08-25T00:00:00Z")!,
            speedCheckedAt: ISO8601DateFormatter().date(from: "2026-08-25T00:00:00Z")!,
            subscriptionSourceURL: source,
            apiSourceURL: api,
            speedSourceURL: speed,
            rates: rates
        )
    }()

    private static func rate(
        model: String,
        serviceTier: String,
        creditsInput: Double,
        creditsCached: Double,
        creditsOutput: Double,
        apiInput: Double,
        apiCached: Double,
        apiOutput: Double
    ) -> V013OfficialPricingRate {
        V013OfficialPricingRate(
            model: model,
            serviceTier: serviceTier,
            creditsInputPerMillion: creditsInput,
            creditsCachedInputPerMillion: creditsCached,
            creditsOutputPerMillion: creditsOutput,
            apiInputPerMillionUSD: apiInput,
            apiCachedInputPerMillionUSD: apiCached,
            apiCacheWritePerMillionUSD: apiInput * 1.25,
            apiOutputPerMillionUSD: apiOutput,
            longContextThreshold: 272_000,
            longContextInputMultiplier: 2,
            longContextOutputMultiplier: 1.5
        )
    }

    private static func normalizedModel(_ value: String) -> String {
        let model = value.lowercased()
        return model == "gpt-5.6" ? "gpt-5.6-sol" : model
    }

    static func normalizedTier(_ value: String?) -> String? {
        switch value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "default", "standard":
            return "standard"
        case "fast", "priority":
            return "fast"
        default:
            return nil
        }
    }

}
